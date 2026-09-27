// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { AvengeHook } from "../src/AvengeHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IERC20Minimal } from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { ChainAddresses } from "./ChainAddresses.sol";

/// @title InitializePoolsWithHookScript
/// @notice Initialize ETH/USDC pools with existing AvengeHook and add liquidity
/// @dev Based on DeployAvengeHookComplete.s.sol but skips hook deployment
contract InitializePoolsWithHook is Script {
    using ChainAddresses for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Deployment configuration (same as DeployAvengeHookComplete.s.sol)
    // LP fee is a liquidityDelta, NOT a token amount: L ~= 1.3e12 puts ~1.95 USDC
    // + ~0.00038 ETH of in-range liquidity into each pool.
    int256 constant LIQUIDITY_DELTA = 1.3e12;
    // Native token attached per modifyLiquidity call; the test router settles the
    // exact amount0 and refunds the remainder to the sender.
    uint256 constant LIQUIDITY_ETH_VALUE = 0.01 ether;
    // Dynamic-fee pool: the key's fee must be DYNAMIC_FEE_FLAG or PoolManager silently
    // ignores the hook's beforeSwap fee override (LPFeeLibrary.isDynamicFee).
    uint24 constant POOL_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    uint24 constant BASE_FEE = 500; // 0.05% base LP fee (pips, 1e6 = 100%)

    // Pool configurations - different tick spacings as requested
    // NOTE: spacing 10/60 was already initialized on-chain at a wrong price with an
    // out-of-range position (state.liquidity == 0) and initialize is irreversible,
    // so fresh keys use new spacings to create correct, in-range pools.
    int24 constant TICK_SPACING_POOL_1 = 30; // Tick spacing for first pool (1200 % 30 == 0)
    int24 constant TICK_SPACING_POOL_2 = 120; // Tick spacing for second pool (1200 % 120 == 0)

    // Price configurations (ETH/USDC) in v4 raw units: currency0 = WETH (18 dec),
    // currency1 = USDC (6 dec) => price = USDC_per_ETH * 1e6 / 1e18.
    // 2500 USDC/ETH => 2.5e-9 => sqrtPriceX96 = sqrt(2.5e-9) * 2^96
    uint160 constant SQRT_PRICE_2500 = 3961408125713216879677197;
    // 2600 USDC/ETH => 2.6e-9 => sqrtPriceX96 = sqrt(2.6e-9) * 2^96
    uint160 constant SQRT_PRICE_2600 = 4039859466863342510789667;

    // Minimum balance requirements
    uint256 constant MIN_ETH_BALANCE = 0.01 ether; // Minimum ETH for operations
    uint256 constant MIN_USDC_BALANCE = 5e6; // Minimum 5 USDC for both pools' liquidity
    
    // Contract instances
    AvengeHook public hook;
    IPoolManager public poolManager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    IERC20Minimal public usdc;
    
    // Pool configurations
    PoolKey public poolKey1; // ETH/USDC at 2500
    PoolKey public poolKey2; // ETH/USDC at 2600
    PoolId public poolId1;
    PoolId public poolId2;
    int24 public tick1;
    int24 public tick2;
    
    // Deployment state
    address public deployer;
    address payable public hookAddress;
    bool public isForked;
    
    // Events
    event PoolInitializationStarted(address indexed hookAddress, uint256 chainId, bool isForked);
    event BalanceChecked(address indexed account, uint256 ethBalance, uint256 usdcBalance, bool sufficient);
    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96, int24 tickSpacing);
    event LiquidityAdded(PoolId indexed poolId, int256 liquidityDelta, uint256 ethAttached);
    event PoolInitializationCompleted(address indexed hook, PoolId poolId1, PoolId poolId2);

    /// @notice Main function to initialize pools with existing hook
    function run() external {
        // Get deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYMENT_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        // Get hook address from environment
        hookAddress = payable(vm.envAddress("HOOK_ADDRESS"));
        
        // Determine if we're on a fork
        isForked = _isForkedEnvironment();
        
        console.log("=== Pool Initialization with Existing AvengeHook ===");
        console.log("Chain ID:", block.chainid);
        console.log("Chain Name:", ChainAddresses.getChainName(block.chainid));
        console.log("Deployer:", deployer);
        console.log("Hook Address:", hookAddress);
        console.log("Is Forked:", isForked);
        console.log("Block Explorer:", ChainAddresses.getBlockExplorer(block.chainid));
        
        emit PoolInitializationStarted(hookAddress, block.chainid, isForked);
        
        // Step 1: Validate hook and check balances
        _validateHookAndCheckBalances();
        
        // Step 2: Initialize contract instances
        _initializeContracts();
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 3: Initialize pools
        _initializePools();
        
        // Step 4: Add liquidity
        _addLiquidity();
        
        vm.stopBroadcast();
        
        // Step 5: Log final summary
        _logDeploymentSummary();
        
        emit PoolInitializationCompleted(hookAddress, poolId1, poolId2);
    }

    /// @notice Determine if we're running on a forked environment
    function _isForkedEnvironment() internal view returns (bool) {
        // Check if coinbase is zero address (indicates local/fork environment)
        return block.coinbase == address(0);
    }

    /// @notice Validate hook exists and check deployer balances
    function _validateHookAndCheckBalances() internal {
        console.log("=== Step 1: Hook Validation & Balance Check ===");
        
        // Validate hook address
        require(hookAddress != address(0), "Hook address cannot be zero");
        require(hookAddress.code.length > 0, "Hook address must contain contract code");
        
        console.log("Hook validation:");
        console.log("  Address:", hookAddress);
        console.log("  Code size:", hookAddress.code.length, "bytes");
        console.log("  [PASS] Hook exists and has code");
        
        // Check balances
        uint256 ethBalance = deployer.balance;
        uint256 usdcBalance = 0;
        
        // Get USDC balance if USDC contract exists
        address usdcAddress = ChainAddresses.getUSDC(block.chainid);
        if (usdcAddress != address(0) && usdcAddress.code.length > 0) {
            usdcBalance = IERC20Minimal(usdcAddress).balanceOf(deployer);
        }
        
        console.log("Balance check:");
        console.log("  ETH Balance:", ethBalance);
        console.log("  USDC Balance:", usdcBalance);
        console.log("  Required ETH:", MIN_ETH_BALANCE);
        console.log("  Required USDC:", MIN_USDC_BALANCE);
        
        bool ethSufficient = ethBalance >= MIN_ETH_BALANCE;
        bool usdcSufficient = usdcBalance >= MIN_USDC_BALANCE;
        bool sufficientBalance = ethSufficient && usdcSufficient;
        
        console.log("  ETH sufficient:", ethSufficient);
        console.log("  USDC sufficient:", usdcSufficient);
        
        if (!sufficientBalance) {
            console.log("");
            console.log("[ERROR] Insufficient balance detected!");
            console.log("===============================================");
            console.log("         POOL INITIALIZATION FAILED!         ");
            console.log("===============================================");
            console.log("");
            console.log("Required balances:");
            console.log("  ETH:  ", MIN_ETH_BALANCE / 1e18, "ETH");
            console.log("  USDC: ", MIN_USDC_BALANCE / 1e6, "USDC");
            console.log("");
            console.log("Current balances:");
            console.log("  ETH:  ", ethBalance / 1e18, "ETH");
            console.log("  USDC: ", usdcBalance / 1e6, "USDC");
            console.log("");
            console.log("Please fund your deployer address:", deployer);
            console.log("Then try again.");
            console.log("");
            
            revert("Insufficient balance for pool operations. Please fund the deployer address.");
        } else {
            console.log("  [PASS] Sufficient balances for pool operations");
        }
        
        emit BalanceChecked(deployer, ethBalance, usdcBalance, sufficientBalance);
    }
    
    /// @notice Initialize contract instances
    function _initializeContracts() internal {
        console.log("=== Step 2: Initialize Contracts ===");
        
        // Validate chain addresses
        if (block.chainid != ChainAddresses.LOCAL_ANVIL) {
            ChainAddresses.validateChainAddresses(block.chainid);
        }
        
        // Get contract addresses
        address poolManagerAddress = ChainAddresses.getPoolManager(block.chainid);
        address usdcAddress = ChainAddresses.getUSDC(block.chainid);
        
        console.log("Contract addresses:");
        console.log("  Pool Manager:", poolManagerAddress);
        console.log("  USDC Token:", usdcAddress);
        console.log("  Hook:", hookAddress);
        
        // Initialize contract instances
        hook = AvengeHook(hookAddress);
        poolManager = IPoolManager(poolManagerAddress);
        usdc = IERC20Minimal(usdcAddress);
        
        // Get PoolModifyLiquidityTest address
        address modifyLiquidityAddress = ChainAddresses.getPoolModifyLiquidityTest(block.chainid);
        require(modifyLiquidityAddress != address(0), "PoolModifyLiquidityTest address not found");
        modifyLiquidityRouter = PoolModifyLiquidityTest(modifyLiquidityAddress);
        console.log("  Modify Liquidity Router:", address(modifyLiquidityRouter));
        
        // Validate hook connection to pool manager
        try hook.poolManager() returns (IPoolManager hookPoolManager) {
            require(address(hookPoolManager) == address(poolManager), "Hook pool manager mismatch");
            console.log("  [PASS] Hook connected to correct pool manager");
        } catch {
            revert("Failed to validate hook pool manager connection");
        }
    }
    
    /// @notice Initialize two pools with different configurations
    function _initializePools() internal {
        console.log("=== Step 3: Initialize Pools ===");
        
        // Setup currencies (ETH and USDC)
        Currency currency0 = Currency.wrap(address(0)); // ETH
        Currency currency1 = Currency.wrap(address(usdc)); // USDC
        
        // Ensure proper ordering (currency0 < currency1)
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }
        
        console.log("Currency configuration:");
        console.log("  Currency0 (ETH):", Currency.unwrap(currency0));
        console.log("  Currency1 (USDC):", Currency.unwrap(currency1));
        console.log("  Currency ordering verified:", Currency.unwrap(currency0) < Currency.unwrap(currency1));
        
        // Create pool keys
        poolKey1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING_POOL_1,
            hooks: IHooks(hookAddress)
        });
        
        poolKey2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING_POOL_2,
            hooks: IHooks(hookAddress)
        });
        
        poolId1 = poolKey1.toId();
        poolId2 = poolKey2.toId();
        
        console.log("=== Pool 1 Configuration ===");
        console.log("PoolKey Details:");
        console.log("  currency0:", Currency.unwrap(poolKey1.currency0));
        console.log("  currency1:", Currency.unwrap(poolKey1.currency1));
        console.log("  lpFee: dynamic, base 500 (0.05%); arb override 3000 (0.30%)");
        console.log("  tickSpacing:", poolKey1.tickSpacing);
        console.log("  hooks:", address(poolKey1.hooks));
        console.log("  Target Price: 2500 USDC/ETH");
        console.log("  sqrtPriceX96:", SQRT_PRICE_2500);
        console.log("  Pool ID:", vm.toString(PoolId.unwrap(poolId1)));
        
        console.log("=== Pool 2 Configuration ===");
        console.log("PoolKey Details:");
        console.log("  currency0:", Currency.unwrap(poolKey2.currency0));
        console.log("  currency1:", Currency.unwrap(poolKey2.currency1));
        console.log("  lpFee: dynamic, base 500 (0.05%); arb override 3000 (0.30%)");
        console.log("  tickSpacing:", poolKey2.tickSpacing);
        console.log("  hooks:", address(poolKey2.hooks));
        console.log("  Target Price: 2600 USDC/ETH");
        console.log("  sqrtPriceX96:", SQRT_PRICE_2600);
        console.log("  Pool ID:", vm.toString(PoolId.unwrap(poolId2)));
        
        // Initialize pools. These tick spacings are unused on-chain, so initialize
        // must succeed - fail loudly instead of silently continuing.
        console.log("Initializing Pool 1...");
        tick1 = poolManager.initialize(poolKey1, SQRT_PRICE_2500);
        console.log("Pool 1 initialized successfully at tick:", tick1);
        _setBaseFee(poolKey1, "Pool 1");

        console.log("Initializing Pool 2...");
        tick2 = poolManager.initialize(poolKey2, SQRT_PRICE_2600);
        console.log("Pool 2 initialized successfully at tick:", tick2);
        _setBaseFee(poolKey2, "Pool 2");
        
        console.log("=== Pools Initialized Successfully ===");
        
        emit PoolInitialized(poolId1, SQRT_PRICE_2500, TICK_SPACING_POOL_1);
        emit PoolInitialized(poolId2, SQRT_PRICE_2600, TICK_SPACING_POOL_2);
    }
    
    /// @notice Dynamic-fee pools start with an LP fee of 0; set the hook's base fee right after init
    function _setBaseFee(PoolKey memory key, string memory label) internal {
        try hook.setDynamicLPFee(key, BASE_FEE) {
            console.log("  Base LP fee set to 500 (0.05%) for", label);
        } catch (bytes memory err) {
            console.log("  [WARN] Base LP fee NOT set for", label, "- pools would charge 0% LP fee");
            console.logBytes(err);
        }
    }
    
    /// @notice Add liquidity to both pools
    function _addLiquidity() internal {
        console.log("=== Step 4: Add Liquidity ===");

        // Approve USDC for liquidity operations
        usdc.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Positions are centered on the pool's actual tick so the mint is in
        // range and PoolManager.state.liquidity is non-zero (an out-of-range
        // mint leaves state.liquidity == 0 and the pool unusable).
        int24 lower1 = _floorToSpacing(tick1 - 600, TICK_SPACING_POOL_1);
        int24 upper1 = lower1 + 1200;
        require(lower1 <= tick1 && tick1 < upper1, "pool1 position must contain tick1");
        int24 lower2 = _floorToSpacing(tick2 - 600, TICK_SPACING_POOL_2);
        int24 upper2 = lower2 + 1200;
        require(lower2 <= tick2 && tick2 < upper2, "pool2 position must contain tick2");

        console.log("Liquidity configuration:");
        console.log("  liquidityDelta:", LIQUIDITY_DELTA);
        console.log("  eth attached per pool (excess refunded):", LIQUIDITY_ETH_VALUE);
        console.log("  Pool 1 range:", lower1);
        console.log("  to:", upper1);
        console.log("  Pool 1 current tick:", tick1);
        console.log("  Pool 2 range:", lower2);
        console.log("  to:", upper2);
        console.log("  Pool 2 current tick:", tick2);

        // Add liquidity to Pool 1
        console.log("Adding liquidity to Pool 1...");
        BalanceDelta delta1 = modifyLiquidityRouter.modifyLiquidity{value: LIQUIDITY_ETH_VALUE}(
            poolKey1,
            ModifyLiquidityParams({
                tickLower: lower1,
                tickUpper: upper1,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            ""
        );
        console.log("Pool 1 liquidity added successfully");
        console.log("  Balance delta amount0:", delta1.amount0());
        console.log("  Balance delta amount1:", delta1.amount1());

        // Add liquidity to Pool 2
        console.log("Adding liquidity to Pool 2...");
        BalanceDelta delta2 = modifyLiquidityRouter.modifyLiquidity{value: LIQUIDITY_ETH_VALUE}(
            poolKey2,
            ModifyLiquidityParams({
                tickLower: lower2,
                tickUpper: upper2,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            ""
        );
        console.log("Pool 2 liquidity added successfully");
        console.log("  Balance delta amount0:", delta2.amount0());
        console.log("  Balance delta amount1:", delta2.amount1());

        // The whole point of the redesign: both pools must now report
        // non-zero in-range liquidity from PoolManager state.
        uint128 inRangeLiq1 = poolManager.getLiquidity(poolId1);
        uint128 inRangeLiq2 = poolManager.getLiquidity(poolId2);
        console.log("In-range liquidity (PoolManager state):");
        console.log("  Pool 1:", inRangeLiq1);
        console.log("  Pool 2:", inRangeLiq2);
        require(inRangeLiq1 > 0, "Pool 1 has zero in-range liquidity");
        require(inRangeLiq2 > 0, "Pool 2 has zero in-range liquidity");

        emit LiquidityAdded(poolId1, LIQUIDITY_DELTA, LIQUIDITY_ETH_VALUE);
        emit LiquidityAdded(poolId2, LIQUIDITY_DELTA, LIQUIDITY_ETH_VALUE);
    }

    /// @notice Floor a tick to a multiple of the spacing (toward negative infinity)
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) {
            rem += spacing;
        }
        return tick - rem;
    }
    
    /// @notice Log comprehensive summary
    function _logDeploymentSummary() internal view {
        console.log("");
        console.log("===============================================");
        console.log("        POOL INITIALIZATION COMPLETE!        ");
        console.log("===============================================");
        console.log("");
        
        console.log("=== Summary ===");
        console.log("Chain:", ChainAddresses.getChainName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("AvengeHook:", hookAddress);
        console.log("Pool Manager:", address(poolManager));
        console.log("USDC Token:", address(usdc));
        console.log("");
        
        console.log("=== Pool 1 Details (ETH/USDC @ 2500) ===");
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId1)));
        console.log("Fee: 500 bps (0.05%)");
        console.log("Tick Spacing:", TICK_SPACING_POOL_1);
        console.log("Target Price: 2500 USDC/ETH");
        console.log("Initial Liquidity: ~1.95 USDC + ~0.00038 ETH (1.3e12)");
        console.log("");

        console.log("=== Pool 2 Details (ETH/USDC @ 2600) ===");
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId2)));
        console.log("Fee: 500 bps (0.05%)");
        console.log("Tick Spacing:", TICK_SPACING_POOL_2);
        console.log("Target Price: 2600 USDC/ETH");
        console.log("Initial Liquidity: ~1.95 USDC + ~0.00038 ETH (1.3e12)");
        console.log("");
        
        console.log("Block Explorer Links:");
        string memory explorerBase = ChainAddresses.getBlockExplorer(block.chainid);
        console.log("Hook Contract:", string.concat(explorerBase, "/address/", vm.toString(hookAddress)));
        console.log("Pool Manager:", string.concat(explorerBase, "/address/", vm.toString(address(poolManager))));
        console.log("");
        
        console.log("[POOLS READY FOR USE]");
        console.log("AvengeHook Address:", hookAddress);
        console.log("Pool 1 ID:", vm.toString(PoolId.unwrap(poolId1)));
        console.log("Pool 2 ID:", vm.toString(PoolId.unwrap(poolId2)));
        console.log("");
    }
} 