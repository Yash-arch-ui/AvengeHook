// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IERC20Minimal } from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { DetoxHook } from "../src/DetoxHook.sol";
import { MockPyth } from "../src/libraries/PythLibrary.sol";

/**
 * @title DetoxHookCaptureTest
 * @notice End-to-end tests that actually execute an arbitrage capture
 *         (take -> donate -> settle -> BeforeSwapDelta) instead of only calling the
 *         `calculateArbitrageOpportunity` view. This is the path that settles the hook's
 *         transient delta to zero inside PoolManager.unlock.
 */
contract DetoxHookCaptureTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    DetoxHook hook;
    MockPyth oracle;

    PoolKey poolKey; // static 0.05% pool
    PoolId poolId;
    PoolKey dynPoolKey; // dynamic-fee pool (base 0.05%)
    PoolId dynPoolId;

    bytes32 constant ETH_USD_PRICE_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant USDC_USD_PRICE_ID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    uint256 constant RHO_BPS = 7000; // capture 70% of the opportunity
    uint256 constant LP_SHARE_BPS = 8000; // 80% of the capture is donated to LPs

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        oracle = new MockPyth(60, 1);
        address hookAddress = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_DONATE_FLAG)
        );
        // owner = address(this) so the test can call onlyOwner helpers directly
        deployCodeTo("DetoxHook.sol", abi.encode(manager, address(this), address(oracle)), hookAddress);
        hook = DetoxHook(payable(hookAddress));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        _addLiquidity(poolKey);

        dynPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        dynPoolId = dynPoolKey.toId();
        manager.initialize(dynPoolKey, SQRT_PRICE_1_1);
        _addLiquidity(dynPoolKey);
        hook.setDynamicLPFee(dynPoolKey, 500);

        hook.setPriceId(currency0, ETH_USD_PRICE_ID);
        hook.setPriceId(currency1, USDC_USD_PRICE_ID);
    }

    // ============ Helpers ============

    function _addLiquidity(PoolKey memory key) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1000e18, salt: 0}),
            ""
        );
    }

    /// @dev MockPyth prices use expo = -8, so the raw value IS the 1e8 price.
    function _setPrices(uint256 currency0Usd1e8, uint256 currency1Usd1e8) internal {
        // $0.01 confidence keeps the band tight enough to register as "outside"
        oracle.updatePriceFeeds(ETH_USD_PRICE_ID, int64(int256(currency0Usd1e8)), uint64(1e6), -8, block.timestamp);
        oracle.updatePriceFeeds(
            USDC_USD_PRICE_ID, int64(int256(currency1Usd1e8)), uint64(1e4), -8, block.timestamp
        );
    }

    function _swapIn(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 spent, uint256 received)
    {
        Currency inCur = zeroForOne ? key.currency0 : key.currency1;
        Currency outCur = zeroForOne ? key.currency1 : key.currency0;

        uint256 inBefore = IERC20Minimal(Currency.unwrap(inCur)).balanceOf(address(this));
        uint256 outBefore = IERC20Minimal(Currency.unwrap(outCur)).balanceOf(address(this));

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        spent = inBefore - IERC20Minimal(Currency.unwrap(inCur)).balanceOf(address(this));
        received = IERC20Minimal(Currency.unwrap(outCur)).balanceOf(address(this)) - outBefore;
    }

    function _params(bool zeroForOne, uint256 amountIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    // ============ Capture tests ============

    /// @notice zeroForOne capture: hook skims its share, donates 80% to LPs, keeps 20%.
    function test_CaptureZeroForOne_PaysLPsAndKeepsShare() public {
        // currency0 (ETH) is $0.90 while the pool prices it at 1.00 -> pool over-pays currency1
        _setPrices(9e7, 1e8);

        (,, bool shouldInterfere, bool outsideBand) =
            hook.calculateArbitrageOpportunity(poolKey, _params(true, 1 ether));
        assertTrue(shouldInterfere, "oracle gap should trigger interference");
        assertTrue(outsideBand, "pool price should be outside the confidence band");

        (uint256 viewOpp, uint256 viewHookShare,,) =
            hook.calculateArbitrageOpportunity(poolKey, _params(true, 1 ether));
        assertGt(viewOpp, 0, "opportunity should be positive");

        uint256 expectedKept = viewHookShare - (viewHookShare * LP_SHARE_BPS) / 10000;
        (uint256 feeGrowth0Before,) = manager.getFeeGrowthGlobals(poolId);

        (uint256 spent, uint256 received) = _swapIn(poolKey, true, 1 ether);

        assertEq(spent, 1 ether, "swapper pays exactly the specified input");
        assertGt(received, 0, "swapper still receives output");

        assertEq(
            IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)),
            expectedKept,
            "hook keeps only its 20% share of the capture"
        );
        assertEq(hook.accumulatedTokens(poolId, currency0), expectedKept, "accumulatedTokens tracks the kept share");

        (uint256 feeGrowth0After,) = manager.getFeeGrowthGlobals(poolId);
        assertGt(feeGrowth0After, feeGrowth0Before, "donation must increase feeGrowthGlobal0 for in-range LPs");
    }

    /// @notice oneForZero capture. This direction used to revert with CurrencyNotSettled.
    function test_CaptureOneForZero_PaysLPsAndKeepsShare() public {
        // currency0 (ETH) is $1.10 -> market is above the pool, selling currency1 is advantageous
        _setPrices(11e7, 1e8);

        (,, bool shouldInterfere, bool outsideBand) =
            hook.calculateArbitrageOpportunity(poolKey, _params(false, 1 ether));
        assertTrue(shouldInterfere, "oracle gap should trigger interference");
        assertTrue(outsideBand, "pool price should be outside the confidence band");

        (, uint256 viewHookShare,,) = hook.calculateArbitrageOpportunity(poolKey, _params(false, 1 ether));
        uint256 expectedKept = viewHookShare - (viewHookShare * LP_SHARE_BPS) / 10000;
        (, uint256 feeGrowth1Before) = manager.getFeeGrowthGlobals(poolId);

        (uint256 spent, uint256 received) = _swapIn(poolKey, false, 1 ether);

        assertEq(spent, 1 ether, "swapper pays exactly the specified input");
        assertGt(received, 0, "swapper still receives output");

        assertEq(
            IERC20Minimal(Currency.unwrap(currency1)).balanceOf(address(hook)),
            expectedKept,
            "hook keeps only its 20% share of the capture"
        );
        assertEq(hook.accumulatedTokens(poolId, currency1), expectedKept, "accumulatedTokens tracks the kept share");

        (, uint256 feeGrowth1After) = manager.getFeeGrowthGlobals(poolId);
        assertGt(feeGrowth1After, feeGrowth1Before, "donation must increase feeGrowthGlobal1 for in-range LPs");
    }

    /// @notice The 0.30% arb fee only applies on dynamic-fee pools: same swap, lower output.
    function test_DynamicFeeOverrideChargesMoreThanStaticPool() public {
        _setPrices(9e7, 1e8);

        (,, bool shouldInterfere,) = hook.calculateArbitrageOpportunity(poolKey, _params(true, 1 ether));
        assertTrue(shouldInterfere, "precondition: capture fires on both pools");

        // Static 0.05% pool: v4 ignores the returned fee override
        (, uint256 receivedStatic) = _swapIn(poolKey, true, 1 ether);
        // Dynamic pool with 0.05% base: override is honored -> 0.30%
        (, uint256 receivedDynamic) = _swapIn(dynPoolKey, true, 1 ether);

        assertGt(receivedStatic, receivedDynamic, "dynamic pool must charge the 0.30% arb fee");

        // The hook must have captured on the dynamic pool as well
        assertGt(
            IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)),
            0,
            "capture must also run on the dynamic-fee pool"
        );
    }

    /// @notice Base fee of the dynamic pool is set by the owner through the hook.
    function test_DynamicPoolBaseFeeIsSet() public view {
        (,,, uint24 lpFee) = manager.getSlot0(dynPoolId);
        assertEq(lpFee, 500, "dynamic pool base fee should be 0.05%");
        assertEq(hook.normalFeePips(), 500, "hook reports the 0.05% base fee");
        assertEq(hook.arbFeePips(), 3000, "hook reports the 0.30% arb fee");
    }

    /// @notice A wildly mispriced pool must be capped at MAX_CAPTURE_BPS (50% of input).
    function test_CaptureCappedAtMaxCaptureBps() public {
        _setPrices(1e6, 1e8); // currency0 = $0.01 vs pool price 1.00

        (,, bool shouldInterfere,) = hook.calculateArbitrageOpportunity(poolKey, _params(true, 1 ether));
        assertTrue(shouldInterfere, "extreme gap should still trigger");

        (uint256 spent,) = _swapIn(poolKey, true, 1 ether);

        uint256 maxCapture = 0.5 ether; // MAX_CAPTURE_BPS = 5000
        uint256 expectedKept = (maxCapture * (10000 - LP_SHARE_BPS)) / 10000;

        assertEq(spent, 1 ether, "swapper still pays exactly the specified input");
        assertEq(
            IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)),
            expectedKept,
            "capture must be capped at 50% of the input amount"
        );
        assertEq(hook.accumulatedTokens(poolId, currency0), expectedKept, "capped share is what gets tracked");
    }

    /// @notice Stale oracle data must disable interference (fallback to a plain swap).
    function test_NoCaptureWhenOracleStale() public {
        _setPrices(9e7, 1e8);
        vm.warp(block.timestamp + 61); // stalenessThreshold = 60s

        (uint256 spent,) = _swapIn(poolKey, true, 1 ether);

        assertEq(spent, 1 ether, "swap still executes normally");
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "no capture on stale oracle");
        assertEq(hook.accumulatedTokens(poolId, currency0), 0, "nothing tracked on stale oracle");
    }

    /// @notice Third-party donate() must not hit BaseHook's reverting default _beforeDonate.
    function test_ExternalDonateDoesNotRevert() public {
        uint256 amountBefore = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));
        donateRouter.donate(poolKey, 1 ether, 0, "");
        uint256 amountAfter = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(this));

        assertEq(amountBefore - amountAfter, 1 ether, "external donate() settles from the donor");
    }

    /// @notice The normal (non-arb) path must not touch any funds.
    function test_NoCaptureWhenPricesAgree() public {
        _setPrices(1e8, 1e8); // market == pool price

        (uint256 spent, uint256 received) = _swapIn(poolKey, true, 1 ether);

        assertEq(spent, 1 ether, "plain swap spends the input");
        assertGt(received, 0, "plain swap pays out");
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "no capture");
        assertEq(hook.accumulatedTokens(poolId, currency0), 0, "nothing tracked");
    }
}
