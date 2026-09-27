// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { BaseHook } from "@v4-periphery/src/utils/BaseHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { toBeforeSwapDelta, BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { IPyth, PythStructs } from "./libraries/PythLibrary.sol";
import { HookLibrary } from "./libraries/HookLibrary.sol";
import { ArbitrageLib } from "./libraries/ArbitrageLib.sol";
import { OracleLib } from "./libraries/OracleLib.sol";
import { IERC20Minimal } from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract DetoxHook is BaseHook {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    // ============ Configuration (mirrors README) ============
    /// @notice Minimum deviation from the global market before the hook interferes (2%)
    uint256 public constant ARBITRAGE_THRESHOLD = 200; // basis points; if the pool price is off from the oracle price by more than 2% , its flagged as an arb opp
    /// @notice Share of the arbitrage opportunity captured by the hook (70%)
    uint256 public constant CAPTURE_RATE = 70; // percent
    /// @notice Share of the captured amount donated to LPs (80%), 20% stays with the protocol
    uint256 public constant LP_SHARE = 80; // percent

    // Internal constants derived from the README parameters
    uint256 private constant RHO_BPS = CAPTURE_RATE * 100; // hook share in basis points
    uint256 private constant LP_DONATE_BPS = LP_SHARE * 100; // 8000 = 80% of hook share donated to LPs; 80% of what the hook captures 
    uint256 private constant STALENESS_THRESHOLD = 60; // Oracle staleness limit in seconds
    uint256 private constant BASIS_POINTS = 10000; // 100% in basis points
    uint256 private constant MAX_CAPTURE_BPS = 5000; // never capture more than 50% of a swap
    uint24 private constant ARB_FEE_PIPS = 3000; // 0.30% LP fee on detected arb swaps (pips: 1e6 = 100%)
    uint24 private constant NORMAL_FEE_PIPS = 500; // 0.05% base LP fee for dynamic-fee pools

    // Chain-specific constants
    address private constant USDC_ON_ARBITRUM = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    address private constant PYTH_ORACLE_ON_ARBITRUM_SEPOLIA = 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF;
    bytes32 private constant ETH_USD_PRICE_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 private constant USDC_USD_PRICE_ID = 0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    // Contract state
    IPyth public immutable pythOracle;
    address public immutable owner;
    mapping(Currency => bytes32) public pythPriceIds;

    // Mapping to track accumulated tokens per pool and token
    mapping(PoolId => mapping(Currency => uint256)) public accumulatedTokens;

    // Configurable parameters
    uint256 public rhoBps;
    uint256 public stalenessThreshold;

    constructor(IPoolManager _poolManager, address _owner, address _oracle) BaseHook(_poolManager) {
        owner = _owner;
        
        // Initialize configurable parameters
        rhoBps = RHO_BPS;
        stalenessThreshold = STALENESS_THRESHOLD;

        // If oracle is provided, use it; otherwise use default logic
        if (_oracle != address(0)) {
            pythOracle = IPyth(_oracle);
        } else if (block.chainid == 421614) {
            // Only initialize Pyth oracle on Arbitrum Sepolia (chain ID 421614)
            pythOracle = IPyth(PYTH_ORACLE_ON_ARBITRUM_SEPOLIA);
        } else {
            // On other chains (like Anvil), set to zero address
            pythOracle = IPyth(address(0));
        }

        // Initialize the price oracle mappings for the currency pairs we need
        pythPriceIds[Currency.wrap(address(0))] = ETH_USD_PRICE_ID;
        pythPriceIds[Currency.wrap(USDC_ON_ARBITRUM)] = USDC_USD_PRICE_ID;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Early exit for exact output swaps - no interference
        if (params.amountSpecified >= 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // 2. Get currencies and oracle prices with confidence
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        (uint256 inputPrice, uint256 inputConf, bool inputValid) = _getOraclePriceWithConfidence(inputCurrency);
        (uint256 outputPrice, uint256 outputConf, bool outputValid) = _getOraclePriceWithConfidence(outputCurrency);

        // 3. Fallback to no interference if oracle fails
        if (!inputValid || !outputValid) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // 4. Get pool price and prepare arbitrage parameters
        uint256 poolPrice = _getPoolPrice(key);
        if (poolPrice == 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // 5. Use ArbitrageLib to analyze opportunity with confidence bounds
        uint256 exactInputAmount = uint256(-params.amountSpecified);
        ArbitrageLib.ArbitrageResult memory result = ArbitrageLib.analyzeArbitrageOpportunity(
            ArbitrageLib.ArbitrageParams({
                poolPrice: poolPrice,
                inputPrice: inputPrice,
                outputPrice: outputPrice,
                inputPriceConf: inputConf,
                outputPriceConf: outputConf,
                exactInputAmount: exactInputAmount,
                zeroForOne: params.zeroForOne
            }),
            rhoBps,
            ARBITRAGE_THRESHOLD
        );

        // 6. Check if we should interfere (confidence, advantage and threshold requirements)
        if (!result.shouldInterfere || result.hookShare == 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // 7. Safety rails: keep the swap itself intact and fit the BeforeSwapDelta type
        uint256 hookShare = result.hookShare;
        uint256 maxCapture = FullMath.mulDiv(exactInputAmount, MAX_CAPTURE_BPS, BASIS_POINTS);
        if (hookShare > maxCapture) hookShare = maxCapture;
        if (hookShare == 0 || hookShare > uint256(int256(type(int128).max))) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // 8. donate() reverts on an empty pool, so don't interfere without LPs to receive the fee
        if (HookLibrary.getPoolLiquidity(poolManager, key) == 0) {
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }

        // 9. Execute arbitrage capture
        return _executeArbitrageCapture(key, params, hookShare, result.arbitrageOpportunity);
    }

    /**
     * @notice Get oracle price with confidence for a currency
     * @param currency The currency to get price for
     * @return price The price in PRICE_PRECISION format
     * @return confidence The confidence in PRICE_PRECISION format
     * @return valid Whether the price is valid and fresh
     */
    function _getOraclePriceWithConfidence(Currency currency) internal view returns (uint256 price, uint256 confidence, bool valid) {
        bytes32 priceId = pythPriceIds[currency];
        return OracleLib.getOraclePriceWithConfidence(pythOracle, priceId, stalenessThreshold);
    }

    /**
     * @notice Get oracle price for a currency (legacy function for backward compatibility)
     * @param currency The currency to get price for
     * @return price The price in PRICE_PRECISION format (8 decimals)
     * @return valid Whether the price is valid and fresh
     */
    function _getOraclePrice(Currency currency) internal view returns (uint256 price, bool valid) {
        (price, , valid) = _getOraclePriceWithConfidence(currency);
    }

    /**
     * @notice Get pool price in the same units as the oracle market price
     * @param key The pool key
     * @return price Whole-token currency1/currency0 price with PRICE_PRECISION (8 decimals)
     * @dev The raw pool ratio is decimal-normalized so pools such as ETH/USDC
     *      (raw ratio ~1e-9) do not truncate to zero.
     */
    function _getPoolPrice(PoolKey memory key) internal view returns (uint256) {
        uint160 sqrtPriceX96 = HookLibrary.getPoolPrice(poolManager, key);
        if (sqrtPriceX96 == 0) return 0;

        return HookLibrary.sqrtPriceToNormalizedPrice(
            sqrtPriceX96,
            HookLibrary.tokenDecimals(key.currency0),
            HookLibrary.tokenDecimals(key.currency1)
        );
    }

    /**
     * @notice Execute arbitrage capture: take tokens, donate LP_SHARE% to LPs, keep the rest
     * @param key The pool key
     * @param params The swap parameters
     * @param hookShare The amount the hook captures from the pool (input currency units)
     * @param arbitrageOpportunity The full opportunity detected (input currency units)
     * @return selector The function selector
     * @return delta The BeforeSwapDelta (reduces swap amount by hookShare)
     * @return fee The dynamic fee override with OVERRIDE_FEE_FLAG
     * @dev The hook's transient delta must end the unlock at zero. `take` credits the hook
     *      with `hookShare` and `donate` debits `lpDonateAmount`, so the donation is settled
     *      from the tokens the hook just took - otherwise PoolManager reverts CurrencyNotSettled.
     */
    function _executeArbitrageCapture(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 hookShare,
        uint256 arbitrageOpportunity
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        // Determine input currency
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Take full hook share from pool
        poolManager.take(inputCurrency, address(this), hookShare);

        // Calculate LP donation: LP_SHARE% (80%) of captured tokens
        uint256 lpDonateAmount = FullMath.mulDiv(hookShare, LP_DONATE_BPS, BASIS_POINTS);

        // Donate to LPs via PoolManager.donate()
        // donate() updates feeGrowthGlobal, distributing fees to in-range LPs
        if (lpDonateAmount > 0) {
            uint256 amount0 = params.zeroForOne ? lpDonateAmount : 0;
            uint256 amount1 = params.zeroForOne ? 0 : lpDonateAmount;
            poolManager.donate(key, amount0, amount1, new bytes(0));

            // Fund the donation out of the captured tokens to clear the hook's delta
            _settleFromBalance(inputCurrency, lpDonateAmount);
        }

        // Track remaining hook share ((100 - LP_SHARE)% kept by hook)
        uint256 hookKept = hookShare - lpDonateAmount;
        PoolId poolId = key.toId();
        accumulatedTokens[poolId][inputCurrency] += hookKept;
        // The specified side of a BeforeSwapDelta is always the input leg for an exact-input
        // swap, regardless of direction. afterSwap maps it back onto the input currency, so it
        // must stay in the specified slot: putting it in the unspecified slot for the
        // oneForZero direction credits currency0 while the hook took currency1 and leaves the
        // hook's transient delta non-zero (CurrencyNotSettled at the end of unlock).
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(hookShare)), 0);

        // Dynamic fee override: 0.30% instead of the 0.05% base fee on detected arbs.
        // v4 only honors the override on dynamic-fee pools (LPFeeLibrary.isDynamicFee),
        // so pools using this hook must be initialized with DYNAMIC_FEE_FLAG.
        uint24 feeOverride = ARB_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        emit ArbitrageCaptured(poolId, inputCurrency, hookShare, arbitrageOpportunity, params.zeroForOne);
        if (lpDonateAmount > 0) {
            emit DonateToLPs(poolId, inputCurrency, lpDonateAmount, hookKept);
        }

        return (BaseHook.beforeSwap.selector, delta, feeOverride);
    }

    /**
     * @notice Pay `amount` of `currency` from the hook's own balance into the PoolManager,
     *         clearing the hook's transient delta for that currency
     * @param currency The currency to settle
     * @param amount The amount to settle (must already be held by this contract)
     */
    function _settleFromBalance(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        if (Currency.unwrap(currency) == address(0)) {
            poolManager.settle{value: amount}();
        } else {
            IERC20Minimal(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /**
     * @notice Set the base LP fee of a dynamic-fee pool that uses this hook (only owner)
     * @param key The pool key (fee must be LPFeeLibrary.DYNAMIC_FEE_FLAG)
     * @param newFee The base LP fee in pips (1e6 = 100%)
     */
    function setDynamicLPFee(PoolKey calldata key, uint24 newFee) external onlyOwner {
        poolManager.updateDynamicLPFee(key, newFee);
    }

    /// @notice Base LP fee applied to dynamic-fee pools when no arbitrage override is active
    function normalFeePips() external pure returns (uint24) {
        return NORMAL_FEE_PIPS;
    }

    /// @notice LP fee charged on a detected arbitrage swap (pips: 1e6 = 100%)
    function arbFeePips() external pure returns (uint24) {
        return ARB_FEE_PIPS;
    }

    /**
     * @notice No-op donate hook: the address is mined with BEFORE_DONATE_FLAG, and BaseHook's
     *         default implementation reverts. Returning the selector keeps third-party
     *         PoolManager.donate() calls working on pools that use this hook.
     */
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    // ============ Owner Functions ============

    /**
     * @notice Update hook parameters (only owner)
     * @param _rhoBps New rho share in basis points
     * @param _stalenessThreshold New staleness threshold in seconds
     */
    function updateParameters(uint256 _rhoBps, uint256 _stalenessThreshold) external onlyOwner {
        require(_rhoBps <= BASIS_POINTS, "Rho BPS too high");
        require(_stalenessThreshold > 0, "Staleness threshold must be positive");

        uint256 oldRhoBps = rhoBps;
        uint256 oldStaleness = stalenessThreshold;

        rhoBps = _rhoBps;
        stalenessThreshold = _stalenessThreshold;

        emit ParametersUpdated(oldRhoBps, _rhoBps, oldStaleness, _stalenessThreshold);
    }

    /**
     * @notice Set price ID for a currency (only owner)
     * @param currency The currency to set price ID for
     * @param priceId The Pyth price ID
     */
    function setPriceId(Currency currency, bytes32 priceId) external onlyOwner {
        bytes32 oldPriceId = pythPriceIds[currency];
        pythPriceIds[currency] = priceId;
        emit PriceIdUpdated(currency, oldPriceId, priceId);
    }

    /**
     * @notice Withdraw accumulated ETH from arbitrage capture (only owner)
     * @param poolId The pool ID to withdraw from
     * @param amount The amount to withdraw in wei
     * @param recipient The address to send ETH to
     */
    function withdrawAccumulatedETH(
        PoolId poolId, 
        uint256 amount, 
        address payable recipient
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than zero");
        
        Currency ethCurrency = Currency.wrap(address(0));
        uint256 available = accumulatedTokens[poolId][ethCurrency];
        require(available >= amount, "Insufficient accumulated ETH");
        
        // Update accumulated tokens
        accumulatedTokens[poolId][ethCurrency] -= amount;
        
        // Transfer ETH to recipient
        recipient.transfer(amount);
        
        emit ETHWithdrawn(poolId, amount, recipient);
    }

    /**
     * @notice Withdraw accumulated ERC20 tokens from arbitrage capture (only owner)
     * @param poolId The pool ID to withdraw from
     * @param currency The ERC20 currency to withdraw (must not be ETH)
     * @param amount The amount to withdraw
     * @param recipient The address to send tokens to
     */
    function withdrawAccumulatedERC20(
        PoolId poolId, 
        Currency currency, 
        uint256 amount, 
        address recipient
    ) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than zero");
        require(Currency.unwrap(currency) != address(0), "Use withdrawAccumulatedETH for ETH");
        
        uint256 available = accumulatedTokens[poolId][currency];
        require(available >= amount, "Insufficient accumulated tokens");
        
        // Update accumulated tokens
        accumulatedTokens[poolId][currency] -= amount;
        
        // Transfer ERC20 tokens to recipient
        IERC20Minimal(Currency.unwrap(currency)).transfer(recipient, amount);
        
        emit ERC20Withdrawn(poolId, currency, amount, recipient);
    }

    /**
     * @notice Get accumulated tokens for a pool and currency
     * @param poolId The pool ID
     * @param currency The currency
     * @return amount The accumulated amount
     */
    function getAccumulatedTokens(PoolId poolId, Currency currency) external view returns (uint256) {
        return accumulatedTokens[poolId][currency];
    }

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {
        // Contract can receive ETH for arbitrage capture
    }

    // ============ View Functions ============

    /**
     * @notice Get the current oracle price for a currency (external view function)
     * @param currency The currency to get price for
     * @return price The price in PRICE_PRECISION format
     * @return valid Whether the price is valid
     * @return publishTime The timestamp when the price was published
     */
    function getOraclePrice(Currency currency) external view returns (uint256 price, bool valid, uint256 publishTime) {
        (price, valid) = _getOraclePrice(currency);
        
        if (valid) {
            bytes32 priceId = pythPriceIds[currency];
            publishTime = OracleLib.getPublishTime(pythOracle, priceId);
        }
    }

    /**
     * @notice Get the current oracle price with confidence for a currency
     * @param currency The currency to get price for
     * @return price The price in PRICE_PRECISION format
     * @return confidence The confidence in PRICE_PRECISION format
     * @return valid Whether the price is valid
     * @return publishTime The timestamp when the price was published
     */
    function getOraclePriceWithConfidence(Currency currency) 
        external 
        view 
        returns (uint256 price, uint256 confidence, bool valid, uint256 publishTime) 
    {
        (price, confidence, valid) = _getOraclePriceWithConfidence(currency);

        if (valid) {
            bytes32 priceId = pythPriceIds[currency];
            publishTime = OracleLib.getPublishTime(pythOracle, priceId);
        }
    }

    /**
     * @notice Calculate potential arbitrage opportunity for a given swap (view function)
     * @param key The pool key
     * @param params The swap parameters
     * @return arbitrageOpp The arbitrage opportunity amount (confidence-adjusted)
     * @return hookShare The amount the hook would capture
     * @return shouldInterfere Whether the hook would interfere
     * @return isOutsideConfidenceBand Whether pool price is outside oracle confidence band
     */
    function calculateArbitrageOpportunity(PoolKey calldata key, SwapParams calldata params)
        external
        view
        returns (uint256 arbitrageOpp, uint256 hookShare, bool shouldInterfere, bool isOutsideConfidenceBand)
    {
        if (params.amountSpecified >= 0) return (0, 0, false, false);

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        (uint256 inputPrice, uint256 inputConf, bool inputValid) = _getOraclePriceWithConfidence(inputCurrency);
        (uint256 outputPrice, uint256 outputConf, bool outputValid) = _getOraclePriceWithConfidence(outputCurrency);

        if (!inputValid || !outputValid) return (0, 0, false, false);

        uint256 poolPrice = _getPoolPrice(key);
        if (poolPrice == 0) return (0, 0, false, false);

        ArbitrageLib.ArbitrageResult memory result = ArbitrageLib.analyzeArbitrageOpportunity(
            ArbitrageLib.ArbitrageParams({
                poolPrice: poolPrice,
                inputPrice: inputPrice,
                outputPrice: outputPrice,
                inputPriceConf: inputConf,
                outputPriceConf: outputConf,
                exactInputAmount: uint256(-params.amountSpecified),
                zeroForOne: params.zeroForOne
            }),
            rhoBps,
            ARBITRAGE_THRESHOLD
        );

        return (result.arbitrageOpportunity, result.hookShare, result.shouldInterfere, result.isOutsideConfidenceBand);
    }

    /**
     * @notice Get current parameters
     * @return rhoBps Current rho share in basis points
     * @return stalenessThreshold Current staleness threshold in seconds
     * @return lpDonateBps Current LP donate percentage in basis points
     */
    function getParameters() external view returns (uint256, uint256, uint256) {
        return (rhoBps, stalenessThreshold, LP_DONATE_BPS);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Events ============

    /**
     * @notice Emitted when arbitrage is captured during a swap
     * @param poolId The pool ID
     * @param currency The input currency
     * @param hookShare The amount captured by the hook
     * @param arbitrageOpportunity The total arbitrage opportunity detected
     * @param zeroForOne The swap direction
     */
    event ArbitrageCaptured(
        PoolId indexed poolId, 
        Currency indexed currency, 
        uint256 hookShare, 
        uint256 arbitrageOpportunity,
        bool zeroForOne
    );

    /**
     * @notice Emitted when hook parameters are updated
     * @param oldRhoBps The previous rho share in basis points
     * @param newRhoBps The new rho share in basis points
     * @param oldStaleness The previous staleness threshold
     * @param newStaleness The new staleness threshold
     */
    event ParametersUpdated(
        uint256 oldRhoBps, 
        uint256 newRhoBps, 
        uint256 oldStaleness, 
        uint256 newStaleness
    );

    /**
     * @notice Emitted when a price ID is updated for a currency
     * @param currency The currency whose price ID was updated
     * @param oldPriceId The previous price ID
     * @param newPriceId The new price ID
     */
    event PriceIdUpdated(
        Currency indexed currency, 
        bytes32 oldPriceId, 
        bytes32 newPriceId
    );

    /**
     * @notice Emitted when accumulated ETH are withdrawn
     * @param poolId The pool ID
     * @param amount The amount withdrawn in wei
     * @param recipient The recipient address
     */
    event ETHWithdrawn(PoolId indexed poolId, uint256 amount, address indexed recipient);

    /**
     * @notice Emitted when accumulated ERC20 tokens are withdrawn
     * @param poolId The pool ID
     * @param currency The currency withdrawn
     * @param amount The amount withdrawn
     * @param recipient The recipient address
     */
    event ERC20Withdrawn(PoolId indexed poolId, Currency indexed currency, uint256 amount, address indexed recipient);

    /**
     * @notice Emitted when captured arbitrage tokens are donated to LPs
     * @param poolId The pool ID
     * @param currency The currency donated
     * @param amount The amount donated to LPs
     * @param hookKept The amount kept by the hook (20%)
     */
    event DonateToLPs(PoolId indexed poolId, Currency indexed currency, uint256 amount, uint256 hookKept);
} 