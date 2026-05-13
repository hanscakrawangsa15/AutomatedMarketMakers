// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    RiskProfile,
    InsuranceClaim,
    InsuranceFundState,
    Position,
    CompoundConfig,
    CompoundResult,
    CompoundUrgency
} from "../types/XenorizeTypes.sol";

interface IXenorizeOracle {
    function getSuggestedRange(
        bytes32 poolId,
        RiskProfile riskProfile
    )
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint256 confidence);
    function getVolatility(
        bytes32 poolId
    ) external view returns (uint256 volatilityBps);
    function getGasCostUSD() external view returns (uint256 gasPriceUSD);
    function getTokenPriceUSD(
        address token
    ) external view returns (uint256 priceUSD, uint256 updatedAt);
}

interface IInsuranceFund {
    function submitClaim(
        InsuranceClaim calldata claim
    ) external returns (uint256 compensated0, uint256 compensated1);
    function deposit(uint256 amount0, uint256 amount1) external;
    function updateTVL(uint256 newTVL) external;
    function getFundState() external view returns (InsuranceFundState memory);
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
    event FundDeposited(
        address indexed source,
        uint256 amount0,
        uint256 amount1
    );
    event ClaimsSuspended(string reason);
    event ClaimsResumed();
}

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}
