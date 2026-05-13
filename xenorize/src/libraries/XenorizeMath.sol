// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library XenorizeMath {

    uint256 internal constant WAD             = 1e18;
    uint256 internal constant BPS_MAX         = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ── Impermanent Loss ─────────────────────────────────────────

    /// @notice IL = 2√r/(1+r) - 1  where r = price_final/price_initial
    /// @return ilWad negative WAD value (e.g. -0.0572e18 = -5.72%)
    function calculateIL(uint256 priceRatioWad) internal pure returns (int256 ilWad) {
        uint256 sqrtR      = sqrtWad(priceRatioWad);
        uint256 numerator  = 2 * sqrtR;
        uint256 denominator = WAD + priceRatioWad;
        uint256 holdFraction = denominator == 0 ? 0 : (numerator * WAD) / denominator;
        ilWad = int256(holdFraction) - int256(WAD);
    }

    /// @notice Absolute IL amount in token0
    function calculateILAmount(
        uint256 initialAmount0,
        uint256 initialAmount1,
        uint256 currentPrice0,
        uint256 initialPrice0
    ) internal pure returns (uint256 ilAmount0) {
        if (initialPrice0 == 0) return 0;
        uint256 priceRatio   = (currentPrice0 * WAD) / initialPrice0;
        int256  ilFraction   = calculateIL(priceRatio);
        if (ilFraction >= 0) return 0;
        uint256 totalValue0  = initialAmount0 + (initialAmount1 * WAD) / initialPrice0;
        ilAmount0 = (uint256(-ilFraction) * totalValue0) / WAD;
    }

    // ── Dynamic Fee ──────────────────────────────────────────────

    /// @notice fee = baseFee + vol_premium + size_premium + mev_premium
    function computeDynamicFee(
        uint24  baseFee,
        uint256 volatilityBps,
        uint256 targetVolBps,
        uint256 swapSizeUSD,
        uint256 poolTVLUSD,
        bool    mevDetected
    ) internal pure returns (uint24 feeBps) {
        uint256 fee = uint256(baseFee);

        // Volatility premium: 0.5 × excess vol
        if (volatilityBps > targetVolBps) {
            fee += (volatilityBps - targetVolBps) / 2;
        }

        // Size premium: 0.2 × (size/TVL - 1%) when swap > 1% of TVL
        if (poolTVLUSD > 0) {
            uint256 sizeRatioBps = (swapSizeUSD * BPS_MAX) / poolTVLUSD;
            if (sizeRatioBps > 100) {
                fee += (sizeRatioBps - 100) / 5;
            }
        }

        // MEV premium: flat 50 BPS
        if (mevDetected) fee += 50;

        feeBps = uint24(fee > BPS_MAX ? BPS_MAX : fee);
    }

    // ── Loyalty Multiplier ───────────────────────────────────────

    /// @notice Piecewise linear approx of e^(-λt) saturation curve
    /// @return multiplierBps  10_000 = 1.0x  …  20_000 = 2.0x
    function computeLoyaltyMultiplier(
        uint256 depositTime,
        uint256 currentTime
    ) internal pure returns (uint256 multiplierBps) {
        if (currentTime <= depositTime) return BPS_MAX;

        uint256 d = (currentTime - depositTime) / 1 days;
        uint256 bonus;

        if      (d <= 30)  bonus = d * 150;
        else if (d <= 90)  bonus = 4_500 + (d - 30)  * 63;
        else if (d <= 180) bonus = 8_300 + (d - 90)  * 17;
        else               bonus = 10_000;

        if (bonus > 10_000) bonus = 10_000;
        multiplierBps = BPS_MAX + bonus;
    }

    /// @notice Loyalty score 0–10_000 for insurance priority
    function computeLoyaltyScore(
        uint256 depositTime,
        uint256 currentTime
    ) internal pure returns (uint256 score) {
        uint256 d = (currentTime - depositTime) / 1 days;
        score = d >= 90 ? BPS_MAX : (d * BPS_MAX) / 90;
    }

    // ── Optimal Range ────────────────────────────────────────────

    /// @notice Range = current ± z·σ·√T converted to ticks
    function computeOptimalRange(
        int24   currentTick,
        uint256 annualVolBps,
        uint256 horizonDays,
        int24   tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        uint256 sqrtH        = sqrtApprox(horizonDays * 1_000);
        uint256 sigmaPeriod  = (annualVolBps * sqrtH) / 19_100;
        uint256 tickDeltaU   = (1_645 * sigmaPeriod * 100_000_000)
                                / (9_999 * 1_000 * 10_000);
        int24 tickDelta      = int24(uint24(tickDeltaU));
        if (tickDelta < tickSpacing * 2) tickDelta = tickSpacing * 2;

        tickLower = ((currentTick - tickDelta) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + tickDelta) / tickSpacing) * tickSpacing;
    }

    // ── Sqrt Helpers ─────────────────────────────────────────────

    function sqrtWad(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) return 0;
        // For x < WAD, starting at x underestimates sqrt; use WAD as upper bound instead
        result = x < WAD ? WAD : x;
        uint256 k = (result + x * WAD / result) / 2;
        while (k < result) { result = k; k = (x * WAD / k + k) / 2; }
    }

    function sqrtApprox(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) return 0;
        result = x;
        uint256 k = (x + 1) / 2;
        while (k < result) { result = k; k = (x / k + k) / 2; }
    }
}
