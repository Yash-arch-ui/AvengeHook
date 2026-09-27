// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

/**
 * @title ArbitrageLib
 * @notice Library for arbitrage opportunity calculations and price normalization
 * @dev All prices are normalized to PRICE_PRECISION (1e8).
 *      `poolPrice` is the Uniswap V4 pool price: currency1 per currency0.
 *      The oracle market price is converted into the same units before comparison.
 */
library ArbitrageLib {
    // Constants
    uint256 internal constant PRICE_PRECISION = 1e8; // 8 decimal precision like USDC
    uint256 internal constant BASIS_POINTS = 10000; // 100% in basis points

    /// @notice Default minimum deviation (in bps) before the hook interferes (2%)
    uint256 internal constant DEFAULT_ARBITRAGE_THRESHOLD_BPS = 200;

    /**
     * @notice Parameters for arbitrage calculation
     * @param poolPrice Pool price (currency1/currency0) with PRICE_PRECISION
     * @param inputPrice Input currency price in USD with PRICE_PRECISION
     * @param outputPrice Output currency price in USD with PRICE_PRECISION
     * @param inputPriceConf Input currency price confidence with PRICE_PRECISION
     * @param outputPriceConf Output currency price confidence with PRICE_PRECISION
     * @param exactInputAmount The exact input amount for the swap
     * @param zeroForOne The swap direction (true = currency0 → currency1)
     */
    struct ArbitrageParams {
        uint256 poolPrice;
        uint256 inputPrice;
        uint256 outputPrice;
        uint256 inputPriceConf;
        uint256 outputPriceConf;
        uint256 exactInputAmount;
        bool zeroForOne;
    }

    /**
     * @notice Result of arbitrage calculation
     * @param arbitrageOpportunity The total arbitrage opportunity amount (input currency units)
     * @param shouldInterfere Whether the opportunity exceeds the threshold and confidence bounds
     * @param hookShare The amount the hook should capture (based on rhoBps)
     * @param isOutsideConfidenceBand Whether pool price is outside oracle confidence band
     */
    struct ArbitrageResult {
        uint256 arbitrageOpportunity;
        bool shouldInterfere;
        uint256 hookShare;
        bool isOutsideConfidenceBand;
    }

    /**
     * @notice Map swap input/output USD prices onto the pool's price units (currency1 per currency0)
     * @dev zeroForOne: input = currency0, output = currency1 → pool units = p(c0)/p(c1)
     *      oneForZero: input = currency1, output = currency0 → pool units = p(c0)/p(c1)
     * @return numerator USD price of currency0 (numerator of the pool price)
     * @return denominator USD price of currency1 (denominator of the pool price)
     * @return numConf Confidence of the numerator price
     * @return denConf Confidence of the denominator price
     */
    function poolUnitRatio(ArbitrageParams memory params)
        internal
        pure
        returns (uint256 numerator, uint256 denominator, uint256 numConf, uint256 denConf)
    {
        if (params.zeroForOne) {
            // input = currency0, output = currency1
            return (params.inputPrice, params.outputPrice, params.inputPriceConf, params.outputPriceConf);
        }
        // input = currency1, output = currency0
        return (params.outputPrice, params.inputPrice, params.outputPriceConf, params.inputPriceConf);
    }

    /**
     * @notice Calculate arbitrage opportunity based on price differences with confidence adjustment
     * @param params The arbitrage calculation parameters
     * @return arbitrageOpp Arbitrage opportunity in input currency units (confidence-adjusted)
     */
    function calculateArbitrageOpportunity(ArbitrageParams memory params) internal pure returns (uint256) {
        if (params.exactInputAmount == 0 || params.inputPrice == 0 || params.outputPrice == 0) {
            return 0;
        }

        (uint256 numerator, uint256 denominator, uint256 numConf, uint256 denConf) = poolUnitRatio(params);
        (uint256 marketPriceLower, uint256 marketPriceUpper) =
            calculateMarketPriceBounds(numerator, denominator, numConf, denConf);

        if (params.zeroForOne) {
            // Selling currency0 for currency1: pool over-pays currency1 when poolPrice > market.
            // Conservative: measure against the upper bound. Result is denominated in currency0.
            if (marketPriceUpper == 0 || params.poolPrice <= marketPriceUpper) return 0;
            return FullMath.mulDiv(params.exactInputAmount, params.poolPrice - marketPriceUpper, marketPriceUpper);
        } else {
            // Selling currency1 for currency0: pool over-pays currency0 when poolPrice < market.
            // Conservative: measure against the lower bound. Result is denominated in currency1.
            if (marketPriceLower == 0 || params.poolPrice >= marketPriceLower) return 0;
            return FullMath.mulDiv(params.exactInputAmount, marketPriceLower - params.poolPrice, params.poolPrice);
        }
    }

    /**
     * @notice Check if pool price is outside oracle confidence band
     * @param params The arbitrage calculation parameters
     * @return isOutside Whether pool price is outside confidence bounds
     */
    function isOutsideConfidenceBand(ArbitrageParams memory params) internal pure returns (bool) {
        if (params.inputPrice == 0 || params.outputPrice == 0) return false;

        (uint256 numerator, uint256 denominator, uint256 numConf, uint256 denConf) = poolUnitRatio(params);
        (uint256 lower, uint256 upper) = calculateMarketPriceBounds(numerator, denominator, numConf, denConf);

        return params.poolPrice < lower || params.poolPrice > upper;
    }

    /**
     * @notice Calculate market price bounds with confidence intervals
     * @param numerator Price that forms the numerator of the ratio
     * @param denominator Price that forms the denominator of the ratio
     * @param numConf Confidence of the numerator
     * @param denConf Confidence of the denominator
     * @return lower Lower bound of the ratio with PRICE_PRECISION
     * @return upper Upper bound of the ratio with PRICE_PRECISION
     */
    function calculateMarketPriceBounds(
        uint256 numerator,
        uint256 denominator,
        uint256 numConf,
        uint256 denConf
    ) internal pure returns (uint256 lower, uint256 upper) {
        if (numerator == 0 || denominator == 0) return (0, 0);

        uint256 numLower = numerator > numConf ? numerator - numConf : 0;
        uint256 numUpper = numerator + numConf;
        // Guard against division by zero when the confidence eats the whole denominator
        uint256 denLower = denominator > denConf ? denominator - denConf : 1;
        uint256 denUpper = denominator + denConf;

        lower = FullMath.mulDiv(numLower, PRICE_PRECISION, denUpper);
        upper = FullMath.mulDiv(numUpper, PRICE_PRECISION, denLower);
    }

    /**
     * @notice Check if we should interfere: outside confidence band, advantageous to the
     *         swapper, and the deviation is at least `thresholdBps` (README: 2% minimum)
     * @param params The arbitrage calculation parameters
     * @return Whether the hook should interfere
     */
    function shouldInterfere(ArbitrageParams memory params, uint256 thresholdBps) internal pure returns (bool) {
        if (!isOutsideConfidenceBand(params)) return false;

        (uint256 numerator, uint256 denominator,, ) = poolUnitRatio(params);
        uint256 marketPrice = calculateMarketPrice(numerator, denominator);
        if (marketPrice == 0 || params.poolPrice == 0) return false;

        // Only intercept swaps where the pool pays the swapper more than the global market
        if (params.zeroForOne) {
            if (params.poolPrice <= marketPrice) return false;
        } else {
            if (params.poolPrice >= marketPrice) return false;
        }

        return calculatePriceDifferencePercentage(params.poolPrice, marketPrice) >= thresholdBps;
    }

    /**
     * @notice Check if we should interfere using the default threshold
     * @param params The arbitrage calculation parameters
     * @return Whether the hook should interfere
     */
    function shouldInterfere(ArbitrageParams memory params) internal pure returns (bool) {
        return shouldInterfere(params, DEFAULT_ARBITRAGE_THRESHOLD_BPS);
    }

    /**
     * @notice Calculate hook's share of arbitrage opportunity
     * @param arbitrageOpp The total arbitrage opportunity
     * @param rhoBps The hook's share percentage in basis points
     * @return hookShare The amount the hook should capture
     */
    function calculateHookShare(uint256 arbitrageOpp, uint256 rhoBps) internal pure returns (uint256) {
        if (arbitrageOpp == 0 || rhoBps == 0) return 0;
        return FullMath.mulDiv(arbitrageOpp, rhoBps, BASIS_POINTS);
    }

    /**
     * @notice Comprehensive arbitrage analysis with the default threshold
     * @param params The arbitrage calculation parameters
     * @param rhoBps The hook's share percentage in basis points
     * @return result Complete arbitrage analysis result
     */
    function analyzeArbitrageOpportunity(ArbitrageParams memory params, uint256 rhoBps)
        internal
        pure
        returns (ArbitrageResult memory)
    {
        return analyzeArbitrageOpportunity(params, rhoBps, DEFAULT_ARBITRAGE_THRESHOLD_BPS);
    }

    /**
     * @notice Comprehensive arbitrage analysis
     * @param params The arbitrage calculation parameters
     * @param rhoBps The hook's share percentage in basis points
     * @param thresholdBps Minimum deviation in bps before interfering
     * @return result Complete arbitrage analysis result
     */
    function analyzeArbitrageOpportunity(ArbitrageParams memory params, uint256 rhoBps, uint256 thresholdBps)
        internal
        pure
        returns (ArbitrageResult memory result)
    {
        result.isOutsideConfidenceBand = isOutsideConfidenceBand(params);
        result.shouldInterfere = shouldInterfere(params, thresholdBps);
        result.arbitrageOpportunity = calculateArbitrageOpportunity(params);

        if (result.shouldInterfere) {
            result.hookShare = calculateHookShare(result.arbitrageOpportunity, rhoBps);
        }
    }

    /**
     * @notice Calculate market price ratio from two USD prices (without confidence)
     * @param numerator USD price forming the numerator
     * @param denominator USD price forming the denominator
     * @return marketPrice The ratio with PRICE_PRECISION
     */
    function calculateMarketPrice(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return FullMath.mulDiv(numerator, PRICE_PRECISION, denominator);
    }

    /**
     * @notice Validate arbitrage parameters
     * @param params The arbitrage parameters to validate
     * @return isValid Whether all parameters are valid
     */
    function validateArbitrageParams(ArbitrageParams memory params) internal pure returns (bool) {
        return params.poolPrice > 0 &&
               params.inputPrice > 0 &&
               params.outputPrice > 0 &&
               params.exactInputAmount > 0;
    }

    /**
     * @notice Calculate percentage difference between pool and market price
     * @param poolPrice Pool price with PRICE_PRECISION
     * @param marketPrice Market price with PRICE_PRECISION
     * @return percentageDiff Percentage difference in basis points
     */
    function calculatePriceDifferencePercentage(
        uint256 poolPrice,
        uint256 marketPrice
    ) internal pure returns (uint256) {
        if (poolPrice == 0 || marketPrice == 0) return 0;

        uint256 diff = poolPrice > marketPrice ?
            poolPrice - marketPrice :
            marketPrice - poolPrice;

        return FullMath.mulDiv(diff, BASIS_POINTS, marketPrice);
    }
}
