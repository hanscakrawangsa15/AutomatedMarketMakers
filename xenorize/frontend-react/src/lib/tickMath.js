/**
 * Tick ↔ Price conversion utilities (mirrors Uniswap V3/V4 TickMath).
 *
 * Formula:  price = 1.0001^tick
 *           tick  = floor( log(price) / log(1.0001) )
 *
 * "Price" here is token1/token0 (how many token1 per token0).
 */

const LOG_1_0001 = Math.log(1.0001);

/** Convert a price (token1/token0) to its nearest tick. */
export function priceToTick(price) {
  if (price <= 0) throw new Error("Price must be > 0");
  return Math.floor(Math.log(price) / LOG_1_0001);
}

/** Convert a tick to price (token1/token0). */
export function tickToPrice(tick) {
  return Math.pow(1.0001, tick);
}

/** Round a tick DOWN to the nearest multiple of tickSpacing. */
export function nearestUsableTick(tick, tickSpacing) {
  const rounded = Math.round(tick / tickSpacing) * tickSpacing;
  return rounded;
}

/**
 * Given lower and upper prices, return valid tick bounds
 * rounded to the nearest tick spacing.
 */
export function priceRangeToTicks(priceLower, priceUpper, tickSpacing = 60) {
  if (priceLower >= priceUpper) throw new Error("Lower price must be < upper price");
  const rawLower = priceToTick(priceLower);
  const rawUpper = priceToTick(priceUpper);
  return {
    tickLower: nearestUsableTick(rawLower, tickSpacing),
    tickUpper: nearestUsableTick(rawUpper, tickSpacing),
  };
}

/** Format a price for display: e.g. 0.000031 or 32,000. */
export function formatPrice(price, decimals = 6) {
  if (price < 0.0001) return price.toExponential(3);
  if (price > 1e6)    return price.toLocaleString(undefined, { maximumFractionDigits: 2 });
  return price.toPrecision(decimals);
}

/** Risk profile → tick spacing mapping (matches XenorizeChainlinkOracle). */
export const TICK_SPACINGS = {
  Conservative: 200,
  Balanced:     60,
  Aggressive:   10,
};

/** Risk profile → horizon days mapping. */
export const HORIZONS = {
  Conservative: 30,
  Balanced:     7,
  Aggressive:   1,
};
