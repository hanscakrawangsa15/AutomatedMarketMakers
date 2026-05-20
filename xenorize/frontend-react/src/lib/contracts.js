// ─── Contract Addresses ───────────────────────────────────────────
// Auto-synced by: node sync-addresses.js  (after forge script AnvilSetup.s.sol --broadcast)
export const ADDRESSES = {
  autoCompounder:   "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",
  insuranceFund:    "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  dynamicFeeHook:   "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
  oracle:           "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
  poolManager:      "",
  token0:           "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  token1:           "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
};

// ─── ABIs (minimal — only functions used by the dashboard) ────────

export const INSURANCE_FUND_ABI = [
  "function getFundState() view returns (tuple(uint256 balance0, uint256 balance1, uint256 totalClaimed0, uint256 totalClaimed1, uint256 pendingClaims, bool claimsSuspended, uint256 lastUpdatedBlock))",
  "function totalTVL() view returns (uint256)",
  "function fundBalance0() view returns (uint256)",
  "function fundBalance1() view returns (uint256)",
  "function totalPaidOut0() view returns (uint256)",
  "function totalPaidOut1() view returns (uint256)",
  "function totalDeposited0() view returns (uint256)",
  "function totalDeposited1() view returns (uint256)",
  "event ClaimPaid(bytes32 indexed positionId, address indexed recipient, uint256 amount0, uint256 amount1)",
  "event FundDeposited(address indexed source, uint256 amount0, uint256 amount1)",
];

export const FEE_HOOK_ABI = [
  "function baseFee() view returns (uint24)",
  "function targetVolBps() view returns (uint256)",
  "function mevThresholdBps() view returns (uint256)",
  "function paused() view returns (bool)",
  "function owner() view returns (address)",
  "function getCurrentFee(bytes32 poolId) view returns (uint24)",
  "function previewFee(bytes32 poolId, uint256 swapAmountUSD, bool mevDetected) view returns (uint24)",
  "function poolTVLUSD(bytes32) view returns (uint256)",
  "event FeeUpdated(bytes32 indexed poolId, uint24 oldFee, uint24 newFee)",
  "event MEVDetected(bytes32 indexed poolId, address indexed swapper, uint256 premiumBps)",
];

export const ORACLE_ABI = [
  "function getVolatility(bytes32 poolId) view returns (uint256 volatilityBps)",
  "function getGasCostUSD() view returns (uint256 gasCostUSD)",
  "function getTokenPriceUSD(address token) view returns (uint256 priceUSD, uint256 updatedAt)",
  "function oracleMaxAge() view returns (uint256)",
  "function owner() view returns (address)",
  "event PriceRecorded(bytes32 indexed poolId, uint256 price)",
];

export const AUTO_COMPOUNDER_ABI = [
  // Tokens (immutable — source of truth for token addresses)
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  // State
  "function totalTVL() view returns (uint256)",
  "function totalPositions() view returns (uint256)",
  "function protocolFeeBps() view returns (uint256)",
  "function keeperRewardBps() view returns (uint256)",
  "function maxTVLCap() view returns (uint256)",
  "function minDepositAmount() view returns (uint256)",
  "function paused() view returns (bool)",
  // Position reads
  "function getPositionsByOwner(address) view returns (bytes32[])",
  "function getPosition(bytes32) view returns (tuple(address owner, bytes32 poolId, tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 depositTime, uint256 lastCompound, uint256 compoundCount, uint256 initialCapital0, uint256 initialCapital1, uint256 totalFees0, uint256 totalFees1, uint256 totalIL0, uint8 riskProfile, uint8 status, bool aiManaged))",
  "function isAIManaged(bytes32) view returns (bool)",
  "function getAIRecommendation(bytes32) view returns (int24 tickLower, int24 tickUpper, uint256 confidence)",
  // Actions — manual
  "function openPosition(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, uint8 riskProfile, tuple(uint256 minProfitUSD, uint256 gasCushionBps, uint256 slippageBps, uint256 maxCompoundsPerDay, bool aiRangeEnabled, bool autoRebalance) config) returns (bytes32)",
  "function openPositionAI(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, uint256 amount0, uint256 amount1, uint8 riskProfile, tuple(uint256 minProfitUSD, uint256 gasCushionBps, uint256 slippageBps, uint256 maxCompoundsPerDay, bool aiRangeEnabled, bool autoRebalance) config) returns (bytes32)",
  "function compoundManual(bytes32 id) returns (tuple(uint256,uint256,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
  "function autoCompound(bytes32 id) returns (tuple(uint256,uint256,int24,int24,uint256,uint256,uint256,uint256,uint256,uint256))",
  "function adjustRange(bytes32 id, int24 newTickLower, int24 newTickUpper)",
  "function closePosition(bytes32 id) returns (uint256, uint256)",
  // Events
  "event PositionOpened(bytes32 indexed id, address indexed owner, bytes32 indexed poolId, int24 tL, int24 tU, uint256 a0, uint256 a1)",
  "event PositionCompounded(bytes32 indexed id, uint256 cycle, int24 tL, int24 tU, uint256 f0, uint256 f1, uint256 il, uint256 net)",
  "event PositionClosed(bytes32 indexed id, address indexed owner, uint256 r0, uint256 r1, uint256 tf0, uint256 tf1, uint256 il, uint256 cycles)",
  "event AIRangeApplied(bytes32 indexed id, int24 tL, int24 tU, uint256 confidence)",
  "event RangeAdjusted(bytes32 indexed id, int24 oldTL, int24 oldTU, int24 newTL, int24 newTU)",
];

// ─── Demo pools for display ───────────────────────────────────────
export const DEMO_POOLS = [
  { name: "ETH/USDC",  id: "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640" },
  { name: "WBTC/ETH",  id: "0x4585fe77225b41b697c938b018e2ac67ac5a20c0" },
  { name: "LINK/ETH",  id: "0xa6cc3c2531fdaa6ae1a3ca84c2855806728693e8" },
];
