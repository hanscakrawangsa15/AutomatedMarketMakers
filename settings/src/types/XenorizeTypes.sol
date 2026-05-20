// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Core Types
// All shared structs, enums, and custom errors used across the system
// ─────────────────────────────────────────────────────────────────

// ─── ENUMS ───────────────────────────────────────────────────────

/// @notice Risk profile chosen by LP when opening a position
enum RiskProfile {
    Conservative, // Wide range ±40%, lower fee, lower IL risk
    Balanced,     // Medium range ±15%, balanced fee/IL
    Aggressive    // Narrow range ±5%, higher fee, higher IL risk
}

/// @notice Current status of an LP position
enum PositionStatus {
    Active,    // In-range, earning fees
    OutOfRange,// Out-of-range, not earning, needs rebalance
    Closed     // Closed by LP or rebalanced
}

/// @notice Urgency level for compound/rebalance decisions
enum CompoundUrgency {
    None,      // No action needed
    Low,       // Fee accumulating, compound when convenient
    Medium,    // Approaching range boundary
    High,      // Near boundary, compound soon
    Immediate  // Out of range, rebalance NOW
}

// ─── STRUCTS ─────────────────────────────────────────────────────

/// @notice Full state of one LP position in the AutoCompounder
struct Position {
    address owner;           // LP wallet address
    bytes32 poolId;          // Uniswap v4 pool identifier
    int24   tickLower;       // Lower tick of position range
    int24   tickUpper;       // Upper tick of position range
    uint128 liquidity;       // Current liquidity units
    uint256 depositTime;     // Block timestamp when opened
    uint256 lastCompound;    // Block timestamp of last compound
    uint256 compoundCount;   // Total number of compound cycles
    uint256 initialCapital0; // Token0 amount at first deposit
    uint256 initialCapital1; // Token1 amount at first deposit
    uint256 totalFees0;      // Cumulative token0 fees collected
    uint256 totalFees1;      // Cumulative token1 fees collected
    uint256 totalIL0;        // Cumulative IL in token0 terms
    RiskProfile riskProfile; // LP's chosen risk profile
    PositionStatus status;   // Current position status
}

/// @notice Parameters controlling auto-compound behavior
struct CompoundConfig {
    uint256 minProfitUSD;       // Min net profit in USD (18 decimals) to trigger compound
    uint256 gasCushionBps;      // Gas buffer in BPS (e.g., 20000 = 2x gas cost)
    uint256 slippageBps;        // Max slippage tolerance (e.g., 50 = 0.5%)
    uint256 maxCompoundsPerDay; // Rate limit: max auto-compounds per 24h
    bool    aiRangeEnabled;     // Use AI oracle for range suggestion
    bool    autoRebalance;      // Auto-rebalance when out of range
}

/// @notice Result returned after a compound execution
struct CompoundResult {
    uint256 newCapital0;    // Token0 balance after compound
    uint256 newCapital1;    // Token1 balance after compound
    int24   newTickLower;   // New range lower bound
    int24   newTickUpper;   // New range upper bound
    uint256 feesCollected0; // Token0 fees collected this cycle
    uint256 feesCollected1; // Token1 fees collected this cycle
    uint256 ilRealized0;    // IL realized this cycle in token0
    uint256 gasCostWei;     // Actual gas cost in wei
    uint256 protocolFee0;   // Protocol fee taken in token0
    uint256 protocolFee1;   // Protocol fee taken in token1
}

/// @notice State of the IL Insurance Fund
struct InsuranceFundState {
    uint256 balance0;          // Token0 balance in fund
    uint256 balance1;          // Token1 balance in fund
    uint256 totalClaimed0;     // All-time claims in token0
    uint256 totalClaimed1;     // All-time claims in token1
    uint256 pendingClaims;     // Queued claim count
    bool    claimsSuspended;   // Emergency suspension flag
    uint256 lastUpdatedBlock;  // Block of last state update
}

/// @notice Input for requesting IL insurance payout
struct InsuranceClaim {
    bytes32 positionId;    // Position that suffered IL
    uint256 ilAmount0;     // IL amount in token0
    uint256 ilAmount1;     // IL amount in token1
    uint256 loyaltyScore;  // LP loyalty score (0-10_000 BPS)
    bytes   proof;         // Optional: ZK proof or oracle attestation
}

/// @notice Dynamic fee parameters updated by oracle
struct FeeState {
    uint24  baseFee;           // Static base fee tier
    uint24  currentDynamicFee; // Current effective fee (base + dynamic)
    uint256 volatilityIndex;   // Realized vol (0-10_000, where 10_000 = 100%)
    uint256 lastFeeUpdate;     // Timestamp of last fee update
    uint256 mevPremium;        // Additional fee for detected MEV (BPS)
}

/// @notice Ring buffer of on-chain tick observations for TWAP volatility
/// @dev Fixed size of 24 slots — rolling 24-hour window at 1 obs/hour cadence
struct ObservationBuffer {
    int24[24]   ticks;       // Pool tick at each observation
    uint256[24] timestamps;  // Block.timestamp at each observation
    uint8       nextIndex;   // Next write slot (ring pointer)
    uint8       count;       // Valid observations recorded (max 24)
}

/// @notice Per-pool fee configuration — overrides global defaults when initialized
struct PoolConfig {
    uint24  baseFee;          // Pool-specific base fee (BPS)
    uint256 targetVolBps;     // Pool-specific calm-market volatility target
    uint256 mevThresholdBps;  // Pool-specific MEV detection threshold
    bool    initialized;      // True once a pool config has been explicitly set
}

// ─── CUSTOM ERRORS ───────────────────────────────────────────────
// Using custom errors instead of require strings saves ~50 gas each

error Xenorize__ZeroAmount();
error Xenorize__InvalidRange(int24 lower, int24 upper);
error Xenorize__PositionNotActive(bytes32 positionId);
error Xenorize__PositionNotOwned(bytes32 positionId, address caller);
error Xenorize__NotProfitable(uint256 feeValue, uint256 gasCost);
error Xenorize__SlippageTooHigh(uint256 actual, uint256 max);
error Xenorize__InsuranceFundDepleted(uint256 available, uint256 requested);
error Xenorize__ClaimsSuspended();
error Xenorize__OracleStalePrice(uint256 lastUpdate, uint256 maxAge);
error Xenorize__OracleInvalidPrice(int256 price);
error Xenorize__Unauthorized(address caller, address required);
error Xenorize__PoolNotInitialized(bytes32 poolId);
error Xenorize__TVLCapExceeded(uint256 current, uint256 cap);
error Xenorize__CompoundRateLimited(uint256 nextAllowed);
error Xenorize__EmergencyPaused();
error Xenorize__InvalidFeeRate(uint256 rate, uint256 max);
error Xenorize__TimelockNotElapsed(uint256 available, uint256 current);
error Xenorize__ZeroAddress();
