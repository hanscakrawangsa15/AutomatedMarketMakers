// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─── Uniswap V4 core types ────────────────────────────────────────
import {PoolKey}         from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency}        from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta}    from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks}          from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager}    from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks}           from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary}    from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

// Re-export so project can import from one place
// Note: "global" keyword only works for types defined in the same file.
// Consumers that need PoolIdLibrary should import it directly from v4-core.

import {
    RiskProfile,
    InsuranceClaim,
    InsuranceFundState,
    Position,
    PositionSnapshot,
    CompoundConfig,
    CompoundResult,
    CompoundUrgency
} from "../types/XenorizeTypes.sol";

// ─── Xenorize Oracle ─────────────────────────────────────────────

interface IXenorizeOracle {
    function getSuggestedRange(bytes32 poolId, RiskProfile riskProfile)
        external view returns (int24 tickLower, int24 tickUpper, uint256 confidence);
    function getVolatility(bytes32 poolId)
        external view returns (uint256 volatilityBps);
    function getGasCostUSD()
        external view returns (uint256 gasPriceUSD);
    function getTokenPriceUSD(address token)
        external view returns (uint256 priceUSD, uint256 updatedAt);
}

// ─── Xenorize Insurance Fund ──────────────────────────────────────

interface IInsuranceFund {
    function submitClaim(InsuranceClaim calldata claim)
        external returns (uint256 compensated0, uint256 compensated1);
    /// @notice Deposit protocol fee income into the vault (no shares minted — increases NAV)
    function depositFee(uint256 amount) external;
    function updateTVL(uint256 newTVL) external;
    function getFundState() external view returns (InsuranceFundState memory);
    function getMaxClaim(bytes32 positionId, uint256 ilAmountUSD, uint256 ilAmount1, uint256 loyaltyScore)
        external view returns (uint256 maxToken0, uint256 maxToken1);
    /// @notice Returns the primary asset address (ERC-4626 underlying)
    function asset() external view returns (address);

    event ClaimPaid(bytes32 indexed positionId, address indexed recipient, uint256 amount0, uint256 amount1);
    event FeeDeposited(address indexed source, uint256 amount);
    event ClaimsSuspended(string reason);
    event ClaimsResumed();
}

interface IILShieldHook {
    event SnapshotCreated(bytes32 indexed snapshotKey, address indexed lp, uint256 price0, uint256 price1);
    event SnapshotUpdated(bytes32 indexed snapshotKey, address indexed lp, uint256 newPrice0, uint256 newPrice1);
    event ILCompensationTriggered(bytes32 indexed snapshotKey, address indexed lp, uint256 ilAmount0, uint256 compensated);
    event ILSkipped(bytes32 indexed snapshotKey, string reason);
}

// ─── Chainlink Aggregator ─────────────────────────────────────────

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}
