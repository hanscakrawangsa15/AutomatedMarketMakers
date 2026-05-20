// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Math Library
//
// Contains all financial math used across the protocol:
//  - IL calculation (standard CFMM formula)
//  - Dynamic fee computation
//  - Loyalty multiplier curve
//  - Range position sizing
//  - Price/tick conversions
// ─────────────────────────────────────────────────────────────────

library XenorizeMath {

    // ─── CONSTANTS ───────────────────────────────────────────────

    uint256 internal constant WAD         = 1e18;        // 1.0 in fixed point
    uint256 internal constant BPS_MAX     = 10_000;      // 100% in basis points
    uint256 internal constant SQRT_RATIO  = 2 ** 96;     // Q64.96 format base
    uint24  internal constant MAX_FEE     = 1_000_000;   // 100% in Uniswap fee units
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ─── IMPERMANENT LOSS ────────────────────────────────────────

    /// @notice Calculate impermanent loss given price ratio
    /// @dev Uses the standard IL formula: IL = 2√r/(1+r) - 1
    ///      Result is in WAD (1e18 = 100%)
    ///      A negative result means loss (IL is always ≤ 0)
    /// @param priceRatioWad Current price / Initial price, in WAD
    /// @return ilWad IL as a negative WAD value (e.g., -5.72e16 = -5.72%)
    function calculateIL(uint256 priceRatioWad) internal pure returns (int256 ilWad) {
        // IL = 2√r/(1+r) - 1
        // We use integer approximation of √r via Babylonian method
        uint256 sqrtR = sqrtWad(priceRatioWad);

        // numerator = 2 * √r * WAD
        uint256 numerator = 2 * sqrtR;

        // denominator = (1 + r) — both in WAD
        uint256 denominator = WAD + priceRatioWad;

        // holdValue_fraction = 2√r / (1+r) — result in WAD
        uint256 holdFraction = (numerator * WAD) / denominator;

        // IL = holdFraction - 1 (can be negative)
        ilWad = int256(holdFraction) - int256(WAD);
        // ilWad ≤ 0 always (LP value ≤ hold value)
    }

    /// @notice Calculate IL in absolute token amounts
    /// @param initialAmount0 Token0 deposited initially
    /// @param initialAmount1 Token1 deposited initially
    /// @param currentPrice0  Current price of token0 in USD (WAD)
    /// @param initialPrice0  Price of token0 at deposit in USD (WAD)
    /// @return ilAmount0 Estimated IL denominated in token0 (always positive)
    function calculateILAmount(
        uint256 initialAmount0,
        uint256 initialAmount1,
        uint256 currentPrice0,
        uint256 initialPrice0
    ) internal pure returns (uint256 ilAmount0) {
        if (initialPrice0 == 0) return 0;

        uint256 priceRatio = (currentPrice0 * WAD) / initialPrice0;
        int256 ilFraction = calculateIL(priceRatio);

        // ilFraction is ≤ 0; we return the absolute value as loss
        if (ilFraction >= 0) return 0;

        // Total initial value in token0 terms
        // Simplification: assume 50/50 initial deposit
        uint256 totalInitialValue0 = initialAmount0 + (initialAmount1 * WAD) / initialPrice0;

        // IL amount = |ilFraction| * totalInitialValue0
        ilAmount0 = (uint256(-ilFraction) * totalInitialValue0) / WAD;
    }

    // ─── DYNAMIC FEE CALCULATION ─────────────────────────────────

    /// @notice Compute the adaptive fee based on market conditions
    /// @dev Fee = baseFee + vol_premium + size_premium + mevPremiumBps
    ///      All inputs in BPS, output capped at 10_000 BPS (100%)
    /// @param baseFee Base fee tier in BPS (e.g., 30 = 0.30%)
    /// @param volatilityBps Current volatility in BPS (10000 = 100% annualized)
    /// @param targetVolBps Target "calm" volatility in BPS
    /// @param swapSizeUSD Size of incoming swap in USD (WAD)
    /// @param poolTVLUSD Total pool TVL in USD (WAD)
    /// @param mevPremiumBps MEV fee premium in BPS (0 = no MEV detected, computed dynamically)
    /// @return feeBps Final fee in BPS, capped at 10_000
    function computeDynamicFee(
        uint24  baseFee,
        uint256 volatilityBps,
        uint256 targetVolBps,
        uint256 swapSizeUSD,
        uint256 poolTVLUSD,
        uint256 mevPremiumBps
    ) internal pure returns (uint24 feeBps) {

        uint256 fee = uint256(baseFee);

        // ── Volatility premium ──────────────────────────────────
        // If vol > target: add 50% of excess volatility as fee premium
        // Fee_vol = 0.5 * max(0, vol_current - vol_target)
        if (volatilityBps > targetVolBps) {
            uint256 excessVol = volatilityBps - targetVolBps;
            fee += excessVol / 2; // 0.5 multiplier
        }

        // ── Size premium ────────────────────────────────────────
        // Large swaps relative to TVL pay extra fee
        // Fee_size = 0.2 * max(0, swapSize/TVL - 0.01)
        // Only applies if swap > 1% of TVL
        if (poolTVLUSD > 0) {
            uint256 sizeRatioBps = (swapSizeUSD * BPS_MAX) / poolTVLUSD;
            if (sizeRatioBps > 100) { // > 1% of TVL
                fee += (sizeRatioBps - 100) / 5; // 0.2 multiplier
            }
        }

        // ── MEV premium ─────────────────────────────────────────
        // Dynamic premium passed in — scales with detected price deviation
        // Redirected to LP insurance fund via afterSwap
        if (mevPremiumBps > 0) {
            fee += mevPremiumBps;
        }

        // Cap at 10_000 BPS (100%) and cast to uint24
        feeBps = uint24(fee > BPS_MAX ? BPS_MAX : fee);
    }

    // ─── REALIZED VOLATILITY ─────────────────────────────────────

    /// @notice Compute annualized realized volatility from on-chain tick observations
    /// @dev Uses the identity: volBps = sqrt(Σ(Δtick²) * SECONDS_PER_YEAR / (N * window))
    ///      Derivation: 1 tick ≈ 0.01% price move → log return = Δtick * 1e-4
    ///      σ²_annual = Σ(Δtick² * 1e-8) / N * (SECONDS_PER_YEAR/window)
    ///      σ_annual_bps = σ_annual * 10000 = sqrt(Σ(Δtick²) * SECONDS_PER_YEAR / (N * window))
    /// @param sumSqTickDiffs Sum of squared tick-to-tick differences over the window
    /// @param numReturns Number of return samples (= observations - 1)
    /// @param windowSeconds Total duration of the observation window in seconds
    /// @return volBps Annualized volatility in BPS (10_000 = 100%), capped at 20_000
    function computeRealizedVolatility(
        uint256 sumSqTickDiffs,
        uint256 numReturns,
        uint256 windowSeconds
    ) internal pure returns (uint256 volBps) {
        if (numReturns == 0 || windowSeconds == 0) return 0;

        // volBps = sqrt(sumSqTickDiffs * SECONDS_PER_YEAR / (numReturns * windowSeconds))
        uint256 inner = (sumSqTickDiffs * SECONDS_PER_YEAR) / (numReturns * windowSeconds);
        volBps = sqrtApprox(inner);

        // Cap at 200% annualized vol (extreme but possible in crypto)
        if (volBps > 20_000) volBps = 20_000;
    }

    // ─── LOYALTY / veLP MULTIPLIER ───────────────────────────────

    /// @notice Calculate loyalty fee multiplier based on deposit duration
    /// @dev Uses exponential saturation curve: mult = 1 + (maxBonus)(1 - e^(-λt))
    ///      λ = 0.02 → half-life ≈ 35 days
    ///      Approaches 2.0x asymptotically at ~180 days
    /// @param depositTime Timestamp when LP deposited
    /// @param currentTime Current block timestamp
    /// @return multiplierBps Multiplier in BPS (10_000 = 1.0x, 20_000 = 2.0x)
    function computeLoyaltyMultiplier(
        uint256 depositTime,
        uint256 currentTime
    ) internal pure returns (uint256 multiplierBps) {

        if (currentTime <= depositTime) return BPS_MAX; // 1.0x base

        uint256 daysElapsed = (currentTime - depositTime) / 1 days;

        // Piecewise linear approximation of exponential curve
        // (cheaper gas than true exp, close enough for incentive purposes)
        //
        // Day 0:   1.00x (10_000 BPS)
        // Day 30:  1.45x (14_500 BPS)
        // Day 90:  1.83x (18_300 BPS)
        // Day 180: 1.98x (19_800 BPS)
        // Day 365: 2.00x (20_000 BPS) — cap

        uint256 bonus;

        if (daysElapsed <= 30) {
            // Slope: 150 BPS per day (4_500 over 30 days)
            bonus = daysElapsed * 150;
        } else if (daysElapsed <= 90) {
            // Slope: 63 BPS per day (3_800 over 60 days)
            bonus = 4_500 + (daysElapsed - 30) * 63;
        } else if (daysElapsed <= 180) {
            // Slope: 17 BPS per day (1_500 over 90 days)
            bonus = 8_300 + (daysElapsed - 90) * 17;
        } else {
            // Cap at 2.0x
            bonus = 10_000;
        }

        // Bonus capped at 10_000 BPS (adds up to 1.0x on top of base 1.0x)
        if (bonus > 10_000) bonus = 10_000;

        multiplierBps = BPS_MAX + bonus; // Returns 10_000 - 20_000
    }

    /// @notice Compute loyalty score for insurance priority (0 - 10_000)
    /// @dev 10_000 = full loyalty, 0 = just deposited
    function computeLoyaltyScore(
        uint256 depositTime,
        uint256 currentTime
    ) internal pure returns (uint256 score) {
        uint256 daysElapsed = (currentTime - depositTime) / 1 days;
        // Saturates at 90 days
        score = daysElapsed >= 90 ? BPS_MAX : (daysElapsed * BPS_MAX) / 90;
    }

    // ─── RANGE SIZING ────────────────────────────────────────────

    /// @notice Compute optimal tick range from price volatility
    /// @dev Range = [P * e^(-z*σ*√T), P * e^(+z*σ*√T)]
    ///      Uses 90% confidence interval (z = 1.645)
    ///      σ is annualized vol, T is time horizon in years
    /// @param currentTick Current active tick of pool
    /// @param annualVolBps Annualized volatility in BPS (10_000 = 100%)
    /// @param horizonDays Time horizon for the position in days
    /// @param tickSpacing Pool's tick spacing (must align output)
    /// @return tickLower Lower bound, aligned to tickSpacing
    /// @return tickUpper Upper bound, aligned to tickSpacing
    function computeOptimalRange(
        int24   currentTick,
        uint256 annualVolBps,
        uint256 horizonDays,
        int24   tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {

        // σ_period = σ_annual * √(T/365) — both in BPS
        // Approximate √(days/365) with integer math
        // We compute tickDelta = z * σ_period converted to ticks
        // Using: price = 1.0001^tick → tick_delta ≈ ln(price_range) / ln(1.0001)
        // ln(1.0001) ≈ 0.00009999 ≈ 1/10001

        // z = 1.645 for 90% CI ≈ 1645 in scaled integer
        uint256 z = 1645; // scaled by 1000

        // σ_period = annualVolBps * sqrt(horizonDays) / sqrt(365)
        // sqrt(365) ≈ 19100 (scaled by 1000)
        uint256 sqrtHorizon = sqrtApprox(horizonDays * 1000); // scaled
        uint256 sigmaPeriodBps = (annualVolBps * sqrtHorizon) / 19100;

        // tickDelta = z * sigmaPeriod / ln(1.0001)
        // ln(1.0001) ≈ 9999/100_000_000
        // So tickDelta = z * sigmaPeriod * 100_000_000 / (9999 * 1000)
        uint256 tickDeltaScaled = (z * sigmaPeriodBps * 100_000_000) / (9_999 * 1_000 * 10_000);

        int24 tickDelta = int24(uint24(tickDeltaScaled));

        // Ensure minimum range of 2x tickSpacing
        if (tickDelta < tickSpacing * 2) {
            tickDelta = tickSpacing * 2;
        }

        // Align to tick spacing
        tickLower = ((currentTick - tickDelta) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + tickDelta) / tickSpacing) * tickSpacing;
    }

    // ─── SQRT HELPERS ────────────────────────────────────────────

    /// @notice Babylonian square root for WAD values
    /// @dev Returns √x where x is in WAD format, result also in WAD
    function sqrtWad(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) return 0;

        // Initial estimate: √(x * 1e18) since result must be in WAD
        // Newton-Raphson iteration
        result = x;
        uint256 k = (x + WAD) / 2;

        while (k < result) {
            result = k;
            k = (x * WAD / k + k) / 2;
        }
    }

    /// @notice Integer square root (for non-WAD values)
    function sqrtApprox(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) return 0;
        result = x;
        uint256 k = (x + 1) / 2;
        while (k < result) {
            result = k;
            k = (x / k + k) / 2;
        }
    }

    // ─── PRICE / TICK CONVERSION ─────────────────────────────────

    /// @notice Convert a tick to price ratio (approximate, for display only)
    /// @dev price = 1.0001^tick
    ///      Not used in critical paths — use TickMath from Uniswap for precision
    /// @return priceWad Approximate price in WAD (token1 per token0)
    function tickToApproxPrice(int24 tick) internal pure returns (uint256 priceWad) {
        // 1.0001^tick ≈ e^(tick * ln(1.0001)) ≈ e^(tick * 0.00009999)
        // For reasonable tick values, we use: price ≈ 1 + tick/10001
        // This is only an approximation — DO NOT use for swap math
        if (tick >= 0) {
            priceWad = WAD + (uint256(uint24(tick)) * WAD) / 10_001;
        } else {
            uint256 absTick = uint256(uint24(-tick));
            priceWad = WAD - (absTick * WAD) / (10_001 + absTick);
        }
    }
}
