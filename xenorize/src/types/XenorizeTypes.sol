// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

enum RiskProfile { Conservative, Balanced, Aggressive }

enum PositionStatus { Active, OutOfRange, Closed }

enum CompoundUrgency { None, Low, Medium, High, Immediate }

struct Position {
    address owner;
    bytes32 poolId;       // keccak hash of PoolKey — used as mapping key
    PoolKey poolKey;      // full V4 PoolKey for PoolManager calls
    int24   tickLower;
    int24   tickUpper;
    uint128 liquidity;    // actual V4 liquidity units
    uint256 depositTime;
    uint256 lastCompound;
    uint256 compoundCount;
    uint256 initialCapital0;
    uint256 initialCapital1;
    uint256 totalFees0;
    uint256 totalFees1;
    uint256 totalIL0;
    RiskProfile    riskProfile;
    PositionStatus status;
    bool    aiManaged;    // true → keeper/AI controls range rebalancing
                          // false → LP keeps manual range, AI only compounds fees
}

struct CompoundConfig {
    uint256 minProfitUSD;
    uint256 gasCushionBps;
    uint256 slippageBps;
    uint256 maxCompoundsPerDay;
    bool    aiRangeEnabled;
    bool    autoRebalance;
}

struct CompoundResult {
    uint256 newCapital0;
    uint256 newCapital1;
    int24   newTickLower;
    int24   newTickUpper;
    uint256 feesCollected0;
    uint256 feesCollected1;
    uint256 ilRealized0;
    uint256 gasCostWei;
    uint256 protocolFee0;
    uint256 protocolFee1;
}

struct InsuranceFundState {
    uint256 balance0;
    uint256 balance1;
    uint256 totalClaimed0;
    uint256 totalClaimed1;
    uint256 pendingClaims;
    bool    claimsSuspended;
    uint256 lastUpdatedBlock;
}

struct InsuranceClaim {
    bytes32 positionId;
    uint256 ilAmount0;
    uint256 ilAmount1;
    uint256 loyaltyScore;
    bytes   proof;
}

struct FeeState {
    uint24  baseFee;
    uint24  currentDynamicFee;
    uint256 volatilityIndex;
    uint256 lastFeeUpdate;
    uint256 mevPremium;
}

// ─── Errors ───────────────────────────────────────────────────────
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
