// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {XenorizeTypes} from "../types/XenorizeTypes.sol";

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Interface Definitions
// ─────────────────────────────────────────────────────────────────

/// @notice Interface for the AI/ML price oracle (off-chain → on-chain bridge)
interface IXenorizeOracle {
    /// @notice Returns the AI-suggested optimal tick range for a pool
    /// @param poolId The pool to get range for
    /// @param riskProfile LP's risk appetite
    /// @return tickLower Suggested lower bound
    /// @return tickUpper Suggested upper bound
    /// @return confidence Confidence score 0-10000 (BPS)
    function getSuggestedRange(
        bytes32 poolId,
        XenorizeTypes.RiskProfile riskProfile
    ) external view returns (int24 tickLower, int24 tickUpper, uint256 confidence);

    /// @notice Returns current realized volatility index
    /// @param poolId The pool to query
    /// @return volatilityBps Volatility in BPS (10000 = 100% annualized vol)
    function getVolatility(bytes32 poolId) external view returns (uint256 volatilityBps);

    /// @notice Returns current gas price estimate in USD
    /// @return gasPriceUSD Estimated gas cost for one compound in USD (18 decimals)
    function getGasCostUSD() external view returns (uint256 gasPriceUSD);

    /// @notice Returns token price in USD
    /// @param token Token address to price
    /// @return priceUSD Price with 18 decimals
    /// @return updatedAt Timestamp of last update
    function getTokenPriceUSD(
        address token
    ) external view returns (uint256 priceUSD, uint256 updatedAt);
}

/// @notice Interface for the IL Insurance Fund
interface IInsuranceFund {
    /// @notice Submit a claim for IL compensation
    /// @param claim The claim details
    /// @return compensated0 Amount of token0 paid out
    /// @return compensated1 Amount of token1 paid out
    function submitClaim(
        XenorizeTypes.InsuranceClaim calldata claim
    ) external returns (uint256 compensated0, uint256 compensated1);

    /// @notice Deposit protocol revenue into the fund
    /// @param amount0 Token0 amount to deposit
    /// @param amount1 Token1 amount to deposit
    function deposit(uint256 amount0, uint256 amount1) external;

    /// @notice Get current fund state
    function getFundState() external view returns (XenorizeTypes.InsuranceFundState memory);

    /// @notice Calculate max eligible claim for a position
    function getMaxClaim(
        bytes32 positionId,
        uint256 ilAmount0,
        uint256 ilAmount1,
        uint256 loyaltyScore
    ) external view returns (uint256 maxToken0, uint256 maxToken1);

    event ClaimPaid(
        bytes32 indexed positionId,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1
    );
    event FundDeposited(address indexed source, uint256 amount0, uint256 amount1);
    event ClaimsSuspended(string reason);
    event ClaimsResumed();
}

/// @notice Interface for the AutoCompounder core contract
interface IAutoCompounder {
    /// @notice Open a new managed LP position
    function openPosition(
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        XenorizeTypes.RiskProfile riskProfile,
        XenorizeTypes.CompoundConfig calldata config
    ) external returns (bytes32 positionId);

    /// @notice Manually trigger compound (callable by owner or keeper)
    function compoundPosition(
        bytes32 positionId,
        int24 newTickLower,
        int24 newTickUpper
    ) external returns (XenorizeTypes.CompoundResult memory);

    /// @notice Close a position and return all funds to LP
    function closePosition(
        bytes32 positionId
    ) external returns (uint256 returned0, uint256 returned1);

    /// @notice Collect fees without changing position
    function collectFees(
        bytes32 positionId
    ) external returns (uint256 fees0, uint256 fees1);

    /// @notice Get current state of a position
    function getPosition(
        bytes32 positionId
    ) external view returns (XenorizeTypes.Position memory);

    /// @notice Get all positions owned by an address
    function getPositionsByOwner(
        address owner
    ) external view returns (bytes32[] memory positionIds);

    /// @notice Calculate urgency level for a position
    function getCompoundUrgency(
        bytes32 positionId
    ) external view returns (XenorizeTypes.CompoundUrgency);

    // Events
    event PositionOpened(
        bytes32 indexed positionId,
        address indexed owner,
        bytes32 indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    );

    event PositionCompounded(
        bytes32 indexed positionId,
        uint256 indexed cycleNumber,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 feesCollected0,
        uint256 feesCollected1,
        uint256 ilRealized0,
        uint256 netProfit0
    );

    event PositionClosed(
        bytes32 indexed positionId,
        address indexed owner,
        uint256 returned0,
        uint256 returned1,
        uint256 totalFeesEarned0,
        uint256 totalFeesEarned1,
        uint256 totalIL0,
        uint256 totalCycles
    );

    event FeesCollected(
        bytes32 indexed positionId,
        uint256 fees0,
        uint256 fees1
    );
}

/// @notice Minimal Chainlink AggregatorV3 interface
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        );

    function decimals() external view returns (uint8);
}
