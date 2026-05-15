// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager}   from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId}         from "@uniswap/v4-core/src/types/PoolId.sol";
import {IXenorizeOracle, AggregatorV3Interface} from "../interfaces/IXenorize.sol";
import {XenorizeMath}   from "../libraries/XenorizeMath.sol";
import {RiskProfile, Xenorize__ZeroAddress, Xenorize__OracleStalePrice, Xenorize__OracleInvalidPrice, Xenorize__Unauthorized} from "../types/XenorizeTypes.sol";

/// @title XenorizeChainlinkOracle
/// @notice On-chain oracle that wraps Chainlink price feeds and computes
///         rolling volatility for dynamic fee and range suggestions.
contract XenorizeChainlinkOracle is IXenorizeOracle {

    // ─── Constants ────────────────────────────────────────────────
    uint256 public constant VOL_WINDOW  = 7;      // rolling price samples for vol
    uint256 public constant WAD         = 1e18;

    // ─── Immutables ───────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    address       public immutable owner;

    // ─── Storage ──────────────────────────────────────────────────
    AggregatorV3Interface public gasFeed;         // ETH/USD for gas cost
    uint256 public oracleMaxAge = 1 hours;

    mapping(address => AggregatorV3Interface) public priceFeeds;

    // Ring-buffer price history per pool for volatility estimation
    mapping(bytes32 => uint256[7]) private _priceHistory;
    mapping(bytes32 => uint8)      private _priceIdx;
    mapping(bytes32 => uint8)      private _priceFilled;

    // ─── Events ───────────────────────────────────────────────────
    event FeedSet(address indexed token, address indexed feed);
    event GasFeedSet(address indexed feed);
    event PriceRecorded(bytes32 indexed poolId, uint256 price);

    // ─── Modifiers ────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert Xenorize__Unauthorized(msg.sender, owner);
        _;
    }

    constructor(IPoolManager _poolManager, address _owner, address _gasFeed) {
        if (address(_poolManager) == address(0) || _owner == address(0))
            revert Xenorize__ZeroAddress();
        poolManager = _poolManager;
        owner       = _owner;
        gasFeed     = AggregatorV3Interface(_gasFeed);
    }

    // ─── IXenorizeOracle ──────────────────────────────────────────

    /// @notice Returns current token price in USD (WAD = $1)
    function getTokenPriceUSD(address token)
        external view override returns (uint256 priceUSD, uint256 updatedAt)
    {
        AggregatorV3Interface feed = priceFeeds[token];
        if (address(feed) == address(0)) return (WAD, block.timestamp); // fallback $1

        (, int256 answer,, uint256 ts,) = feed.latestRoundData();
        if (block.timestamp - ts > oracleMaxAge)
            revert Xenorize__OracleStalePrice(ts, oracleMaxAge);
        if (answer <= 0)
            revert Xenorize__OracleInvalidPrice(answer);

        uint8 dec = feed.decimals();
        priceUSD  = dec <= 18
            ? uint256(answer) * (10 ** (18 - dec))
            : uint256(answer) / (10 ** (dec - 18));
        updatedAt = ts;
    }

    /// @notice Returns rolling volatility in BPS for a pool.
    ///         Based on the std-dev of the last VOL_WINDOW price samples.
    function getVolatility(bytes32 poolId) external view override returns (uint256 volatilityBps) {
        uint8 filled = _priceFilled[poolId];
        if (filled < 2) return 3_000; // default 30% if insufficient data

        uint256[7] storage hist = _priceHistory[poolId];
        uint256 n = uint256(filled < VOL_WINDOW ? filled : VOL_WINDOW);

        // Compute mean
        uint256 sum;
        for (uint256 i; i < n; i++) sum += hist[i];
        uint256 mean = sum / n;
        if (mean == 0) return 3_000;

        // Compute variance (as sum of squared relative deviations in BPS)
        uint256 variance;
        for (uint256 i; i < n; i++) {
            uint256 diff = hist[i] > mean ? hist[i] - mean : mean - hist[i];
            uint256 relBps = (diff * 10_000) / mean; // relative deviation in BPS
            variance += relBps * relBps;
        }
        variance /= n;

        // volatility ≈ sqrt(variance) in BPS, annualized x sqrt(365)
        uint256 dailyVolBps = XenorizeMath.sqrtApprox(variance);
        volatilityBps = (dailyVolBps * 191) / 10; // *sqrt(365) ≈ 19.1, scaled
        if (volatilityBps > 100_000) volatilityBps = 100_000; // cap 1000%
    }

    /// @notice Suggests an optimal tick range using XenorizeMath + current volatility.
    function getSuggestedRange(bytes32 poolId, RiskProfile profile)
        external view override
        returns (int24 tickLower, int24 tickUpper, uint256 confidence)
    {
        uint256 vol = this.getVolatility(poolId);

        uint256 horizonDays = profile == RiskProfile.Conservative ? 30
                            : profile == RiskProfile.Balanced      ? 7
                            : 1;

        int24 tickSpacing = profile == RiskProfile.Conservative ? int24(200)
                          : profile == RiskProfile.Balanced      ? int24(60)
                          : int24(10);

        (tickLower, tickUpper) = XenorizeMath.computeOptimalRange(
            0, vol, horizonDays, tickSpacing
        );
        confidence = vol < 3_000 ? 9_000 : vol < 7_000 ? 7_500 : 6_000;
    }

    /// @notice Returns estimated gas cost in USD (WAD).
    function getGasCostUSD() external view override returns (uint256 gasCostUSD) {
        if (address(gasFeed) == address(0)) return 0.50e18; // fallback $0.50
        try gasFeed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 ts, uint80) {
            if (answer > 0 && block.timestamp - ts <= oracleMaxAge) {
                uint256 ethUsd    = uint256(answer) * 1e10; // 8 dec -> 18 dec
                uint256 gasUnits  = 200_000;                // est. compound gas
                uint256 gasWei    = gasUnits * block.basefee;
                gasCostUSD = (gasWei * ethUsd) / 1e18;
                return gasCostUSD;
            }
        } catch {}
        return 0.50e18;
    }

    // ─── Price Recording (called by keeper) ───────────────────────

    /// @notice Records a current price snapshot for a pool (used for vol calculation).
    ///         Anyone can call — price is fetched from Chainlink, not user-supplied.
    function recordPrice(bytes32 poolId, address token) external {
        AggregatorV3Interface feed = priceFeeds[token];
        if (address(feed) == address(0)) return;

        (, int256 answer,, uint256 ts,) = feed.latestRoundData();
        if (answer <= 0 || block.timestamp - ts > oracleMaxAge) return;

        uint256[7] storage hist = _priceHistory[poolId];
        uint8 idx = _priceIdx[poolId];
        hist[idx] = uint256(answer);
        _priceIdx[poolId]    = uint8((idx + 1) % VOL_WINDOW);
        if (_priceFilled[poolId] < VOL_WINDOW) _priceFilled[poolId]++;

        emit PriceRecorded(poolId, uint256(answer));
    }

    // ─── Admin ────────────────────────────────────────────────────

    function setFeed(address token, address feed) external onlyOwner {
        if (token == address(0)) revert Xenorize__ZeroAddress();
        priceFeeds[token] = AggregatorV3Interface(feed);
        emit FeedSet(token, feed);
    }

    function setGasFeed(address feed) external onlyOwner {
        gasFeed = AggregatorV3Interface(feed);
        emit GasFeedSet(feed);
    }

    function setOracleMaxAge(uint256 maxAge) external onlyOwner {
        oracleMaxAge = maxAge;
    }
}
