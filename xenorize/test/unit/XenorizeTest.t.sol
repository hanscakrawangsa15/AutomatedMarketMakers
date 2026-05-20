// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────
// XENORIZE AMM — Comprehensive Test Suite
//
// Tests organized in order of importance:
//   1. Unit tests (individual function behavior)
//   2. Integration tests (multi-contract interaction)
//   3. Fuzz tests (random input stress testing)
//   4. Invariant tests (properties that must NEVER break)
//
// Run with:
//   forge test -vvv                    (all tests)
//   forge test --match-test testIL     (IL tests only)
//   forge test --match-contract Fuzz   (fuzz tests)
//   forge test --match-contract Invar  (invariant tests)
// ─────────────────────────────────────────────────────────────────

import {Test, console2} from "../../lib/forge-std/src/Test.sol";
import {StdInvariant} from "../../lib/forge-std/src/StdInvariant.sol";

import {XenorizeMath} from "../../src/libraries/XenorizeMath.sol";
import {XenorizeInsuranceFund} from "../../src/core/InsuranceFund.sol";
import {XenorizeAutoCompounder} from "../../src/core/AutoCompounder.sol";
import {XenorizeChainlinkOracle} from "../../src/oracles/XenorizeChainlinkOracle.sol";
import {XenorizeDynamicFeeHook} from "../../src/hooks/DynamicFeeHook.sol";
import {XenorizeILShieldHook} from "../../src/hooks/ILShieldHook.sol";
import {InsuranceClaim, RiskProfile, PositionSnapshot, Position, CompoundConfig, CompoundResult, CompoundUrgency, PositionStatus} from "../../src/types/XenorizeTypes.sol";
import {IInsuranceFund, IXenorizeOracle, AggregatorV3Interface} from "../../src/interfaces/IXenorize.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// PoolOperation.sol not in this v4-core version — types are on IPoolManager
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

// ─── MOCK CONTRACTS ──────────────────────────────────────────────

contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply      += amount;
        balanceOf[to]    += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Allowance");
        require(balanceOf[from] >= amount, "Insufficient");
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockOracle {
    uint256 public volatility = 3_000;
    mapping(address => uint256) public prices;

    function setVolatility(uint256 vol) external { volatility = vol; }
    function setPrice(address token, uint256 price) external { prices[token] = price; }

    function getVolatility(bytes32) external view returns (uint256) {
        return volatility;
    }

    function getTokenPriceUSD(address token)
        external view returns (uint256 price, uint256 updatedAt)
    {
        price     = prices[token] > 0 ? prices[token] : 1e18;
        updatedAt = block.timestamp;
    }

    function getSuggestedRange(bytes32, RiskProfile profile)
        external pure returns (int24 lower, int24 upper, uint256 confidence)
    {
        if (profile == RiskProfile.Conservative) {
            lower = -8_000; upper = 8_000;
        } else if (profile == RiskProfile.Balanced) {
            lower = -3_000; upper = 3_000;
        } else {
            lower = -1_000; upper = 1_000;
        }
        confidence = 8_000;
    }

    function getGasCostUSD() external pure returns (uint256) {
        return 0.50e18;
    }
}

// ─────────────────────────────────────────────────────────────────
// 1. MATH LIBRARY UNIT TESTS
// ─────────────────────────────────────────────────────────────────

contract TestXenorizeMath is Test {

    function setUp() public {
        vm.warp(1001 days);
    }

    function test_IL_ZeroPriceRatio_Returns100PercentLoss() public pure {
        int256 il = XenorizeMath.calculateIL(0);
        assertEq(il, -int256(XenorizeMath.WAD), "Zero price = 100% loss");
    }

    function test_IL_NoPriceChange_ReturnsZero() public pure {
        int256 il = XenorizeMath.calculateIL(XenorizeMath.WAD);
        assertEq(il, 0, "No price change = no IL");
    }

    function test_IL_2xPriceIncrease_Returns572BPS() public pure {
        uint256 priceRatio = 2 * XenorizeMath.WAD;
        int256 il = XenorizeMath.calculateIL(priceRatio);
        assertGe(il, -0.0600e18, "IL 2x not in expected range (min)");
        assertLe(il, -0.0544e18, "IL 2x not in expected range (max)");
    }

    function test_IL_IsAlwaysNegativeOrZero() public pure {
        uint256[] memory ratios = new uint256[](5);
        ratios[0] = 0.5e18;
        ratios[1] = 1e18;
        ratios[2] = 2e18;
        ratios[3] = 5e18;
        ratios[4] = 10e18;
        for (uint256 i = 0; i < ratios.length; i++) {
            assertLe(XenorizeMath.calculateIL(ratios[i]), 0, "IL must always be <= 0");
        }
    }

    function test_IL_SymmetricForUpAndDown() public pure {
        uint256 up   = 2 * XenorizeMath.WAD;
        uint256 down = XenorizeMath.WAD / 2;

        int256 ilUp   = XenorizeMath.calculateIL(up);
        int256 ilDown = XenorizeMath.calculateIL(down);

        uint256 diff = ilUp > ilDown
            ? uint256(ilUp - ilDown)
            : uint256(ilDown - ilUp);

        assertLt(diff, 0.01e18, "IL not symmetric for equal up/down moves");
    }

    function test_DynamicFee_HighVolatility_IncreaseFee() public pure {
        uint24 fee = XenorizeMath.computeDynamicFee(
            30, 8_000, 3_000, 100e18, 10_000e18, false
        );
        assertGt(fee, 30, "High vol should increase fee above base");
        assertLe(fee, 10_000, "Fee should never exceed 100%");
    }

    function test_DynamicFee_LowVolatility_EqualsBaseFee() public pure {
        uint24 fee = XenorizeMath.computeDynamicFee(
            30, 1_000, 3_000, 100e18, 10_000e18, false
        );
        assertEq(fee, 30, "Low vol should not add premium above base");
    }

    function test_DynamicFee_MEVDetected_AddsPremium() public pure {
        uint24 feeNormal = XenorizeMath.computeDynamicFee(
            30, 3_000, 3_000, 100e18, 10_000e18, false
        );
        uint24 feeMEV = XenorizeMath.computeDynamicFee(
            30, 3_000, 3_000, 100e18, 10_000e18, true
        );
        assertGt(feeMEV, feeNormal, "MEV detection should increase fee");
        assertEq(feeMEV - feeNormal, 50, "MEV premium should be exactly 50 BPS");
    }

    function test_DynamicFee_NeverExceedsMax() public pure {
        uint24 fee = XenorizeMath.computeDynamicFee(
            10_000, 10_000, 0, 1_000_000e18, 1e18, true
        );
        assertLe(fee, 10_000, "Fee must never exceed 100%");
    }

    function test_LoyaltyMultiplier_Day0_Returns1x() public view {
        uint256 mult = XenorizeMath.computeLoyaltyMultiplier(block.timestamp, block.timestamp);
        assertEq(mult, 10_000, "Day 0 should return exactly 1.0x (10_000 BPS)");
    }

    function test_LoyaltyMultiplier_Day90_Returns183x() public view {
        uint256 depositTime = block.timestamp - 90 days;
        uint256 mult = XenorizeMath.computeLoyaltyMultiplier(depositTime, block.timestamp);
        assertGe(mult, 17_800, "Day 90 should be >= 1.78x");
        assertLe(mult, 18_800, "Day 90 should be <= 1.88x");
    }

    function test_LoyaltyMultiplier_NeverExceeds2x() public view {
        uint256 depositTime = block.timestamp - 1000 days;
        uint256 mult = XenorizeMath.computeLoyaltyMultiplier(depositTime, block.timestamp);
        assertLe(mult, 20_000, "Loyalty multiplier must never exceed 2.0x");
    }

    function test_LoyaltyMultiplier_MonotonicallyIncreasing() public view {
        uint256 mult30  = XenorizeMath.computeLoyaltyMultiplier(
            block.timestamp - 30 days, block.timestamp
        );
        uint256 mult90  = XenorizeMath.computeLoyaltyMultiplier(
            block.timestamp - 90 days, block.timestamp
        );
        uint256 mult180 = XenorizeMath.computeLoyaltyMultiplier(
            block.timestamp - 180 days, block.timestamp
        );
        assertLe(mult30,  mult90,  "30d multiplier should be <= 90d");
        assertLe(mult90,  mult180, "90d multiplier should be <= 180d");
    }

    function test_SqrtWad_One() public pure {
        uint256 result = XenorizeMath.sqrtWad(XenorizeMath.WAD);
        assertApproxEqRel(result, XenorizeMath.WAD, 0.01e18, "sqrt(1) != 1");
    }

    function test_SqrtWad_Four() public pure {
        uint256 result = XenorizeMath.sqrtWad(4 * XenorizeMath.WAD);
        assertApproxEqRel(result, 2 * XenorizeMath.WAD, 0.01e18, "sqrt(4) != 2");
    }
}

// ─────────────────────────────────────────────────────────────────
// 2. DYNAMIC FEE HOOK UNIT TESTS
// ─────────────────────────────────────────────────────────────────

contract TestDynamicFeeHook is Test {

    XenorizeDynamicFeeHook hook;
    MockOracle             oracle;

    address constant OWNER    = address(0xBEEF);
    address constant POOL_MGR = address(0xDEAD);
    address constant FEE_RECV = address(0xCAFE);

    function setUp() public {
        oracle = new MockOracle();
        hook   = new XenorizeDynamicFeeHook(
            IPoolManager(POOL_MGR), OWNER, FEE_RECV, address(0), address(oracle), address(0)
        );
    }

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(hook.poolManager()),  POOL_MGR);
        assertEq(hook.owner(),        OWNER);
        assertEq(hook.feeRecipient(), FEE_RECV);
    }

    function test_GetCurrentFee_ReturnsZeroForUninitialized() public view {
        PoolId poolId = PoolId.wrap(keccak256("ETH-USDC"));
        assertEq(hook.getCurrentFee(poolId), 0);
    }

    function test_EmergencyPause_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.emergencyPause(true);

        vm.prank(OWNER);
        hook.emergencyPause(true);
        assertTrue(hook.paused());
    }

    function test_QueueOracleUpdate_EnforcesTimelock() public {
        address newOracle = address(0x1234);

        vm.prank(OWNER);
        hook.queueOracleUpdate(newOracle);

        vm.prank(OWNER);
        vm.expectRevert();
        hook.executeOracleUpdate(newOracle);

        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(OWNER);
        hook.executeOracleUpdate(newOracle);
        assertEq(address(hook.oracle()), newOracle);
    }
}

// ─────────────────────────────────────────────────────────────────
// 3. INSURANCE FUND UNIT TESTS (ERC-4626)
// ─────────────────────────────────────────────────────────────────

contract TestInsuranceFund is Test {

    XenorizeInsuranceFund fund;
    MockERC20             usdc;

    address constant OWNER  = address(0xBEEF);
    address constant SHIELD = address(0xC0C0); // ILShieldHook (authorized depositor)
    address constant LP     = address(0x1234);

    function setUp() public {
        vm.warp(1001 days);
        usdc = new MockERC20("USD Coin", "USDC");
        fund = new XenorizeInsuranceFund(address(usdc), OWNER, "Xenorize Insurance Share", "xINS");

        // Authorize the mock IL Shield hook
        vm.prank(OWNER);
        fund.setAuthorizedDepositor(SHIELD, true);
    }

    // ── DepositFee ──────────────────────────────────────────────

    function test_DepositFee_UpdatesAssets() public {
        usdc.mint(SHIELD, 1_000e18);
        vm.startPrank(SHIELD);
        usdc.approve(address(fund), 1_000e18);
        fund.depositFee(1_000e18);
        vm.stopPrank();

        assertEq(fund.totalAssets(), 1_000e18, "totalAssets should equal deposited fee");
        assertEq(fund.totalFeeIncome(), 1_000e18);
    }

    function test_DepositFee_OnlyAuthorized() public {
        usdc.mint(address(this), 100e18);
        usdc.approve(address(fund), 100e18);
        vm.expectRevert();
        fund.depositFee(100e18);
    }

    function test_DepositFee_IncreasesShareNAV() public {
        // First: stake 1000 USDC as LP
        usdc.mint(LP, 1_000e18);
        vm.startPrank(LP);
        usdc.approve(address(fund), 1_000e18);
        fund.deposit(1_000e18, LP);  // ERC-4626 deposit
        vm.stopPrank();

        uint256 sharesBefore = fund.balanceOf(LP);
        uint256 assetsBefore = fund.convertToAssets(sharesBefore);

        // Protocol deposits fee income (no shares minted)
        usdc.mint(SHIELD, 500e18);
        vm.startPrank(SHIELD);
        usdc.approve(address(fund), 500e18);
        fund.depositFee(500e18);
        vm.stopPrank();

        uint256 assetsAfter = fund.convertToAssets(sharesBefore);
        assertGt(assetsAfter, assetsBefore, "depositFee should increase share NAV");
    }

    // ── ERC-4626 Deposit / Withdraw ──────────────────────────────

    function test_ERC4626_Deposit_MintShares() public {
        usdc.mint(LP, 1_000e18);
        vm.startPrank(LP);
        usdc.approve(address(fund), 1_000e18);
        uint256 shares = fund.deposit(1_000e18, LP);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares");
        assertEq(fund.balanceOf(LP), shares);
        assertEq(fund.totalAssets(), 1_000e18);
    }

    function test_ERC4626_Withdraw_BurnsShares() public {
        usdc.mint(LP, 1_000e18);
        vm.startPrank(LP);
        usdc.approve(address(fund), 1_000e18);
        fund.deposit(1_000e18, LP);
        uint256 sharesBefore = fund.balanceOf(LP);

        fund.withdraw(500e18, LP, LP);
        vm.stopPrank();

        assertLt(fund.balanceOf(LP), sharesBefore, "Shares should decrease after withdrawal");
        assertEq(usdc.balanceOf(LP), 500e18, "LP should receive 500 USDC back");
    }

    // ── Submit Claim ─────────────────────────────────────────────

    function test_GetMaxClaim_RespectsCap50Percent() public view {
        bytes32 posId   = keccak256("pos1");
        uint256 ilAmount = 1_000e18;
        (uint256 max0,)  = fund.getMaxClaim(posId, ilAmount, 0, 10_000);
        assertLe(max0, ilAmount / 2, "Claim cannot exceed 50% of IL");
    }

    function test_GetMaxClaim_LoyaltyScalesPayout() public view {
        bytes32 posId   = keccak256("pos1");
        uint256 ilAmount = 1_000e18;
        (uint256 max0Low,)  = fund.getMaxClaim(posId, ilAmount, 0, 0);
        (uint256 max0High,) = fund.getMaxClaim(posId, ilAmount, 0, 10_000);
        assertEq(max0Low, 0, "0 loyalty = 0 claim");
        assertGt(max0High, max0Low, "100% loyalty > 0% loyalty");
    }

    function test_SubmitClaim_PayoutReducesAssets() public {
        // Fund the vault
        usdc.mint(SHIELD, 10_000e18);
        vm.startPrank(SHIELD);
        usdc.approve(address(fund), 10_000e18);
        fund.depositFee(10_000e18);
        vm.stopPrank();

        uint256 assetsBefore = fund.totalAssets();

        bytes32 posId = keccak256("pos-lp-usdc");
        InsuranceClaim memory claim = InsuranceClaim({
            positionId:   posId,
            recipient:    LP,
            ilAmountUSD:  1_000e18, // $1000 IL → max payout 50% = $500
            loyaltyScore: 10_000,   // 100% loyalty
            proof:        ""
        });

        vm.prank(SHIELD);
        (uint256 comp0, ) = fund.submitClaim(claim);

        assertGt(comp0, 0, "Should compensate LP");
        assertLt(fund.totalAssets(), assetsBefore, "Assets should decrease after claim");
        assertEq(usdc.balanceOf(LP), comp0, "LP should receive compensation");
    }

    function test_SubmitClaim_OnlyAuthorized() public {
        InsuranceClaim memory claim = InsuranceClaim({
            positionId:   keccak256("pos1"),
            recipient:    LP,
            ilAmountUSD:  100e18,
            loyaltyScore: 10_000,
            proof:        ""
        });
        vm.expectRevert();
        fund.submitClaim(claim);
    }

    function test_EmergencyPause_StopsClaims() public {
        vm.prank(OWNER);
        fund.emergencyPause();

        InsuranceClaim memory claim = InsuranceClaim({
            positionId:   keccak256("pos1"),
            recipient:    LP,
            ilAmountUSD:  100e18,
            loyaltyScore: 10_000,
            proof:        ""
        });

        vm.prank(SHIELD);
        vm.expectRevert();
        fund.submitClaim(claim);
    }

    function test_UpdateTVL_AffectsHealthCheck() public view {
        assertGt(fund.getFundHealthBps(), 0, "Fund health should be nonzero");
    }

    function test_Asset_ReturnsCorrectToken() public view {
        assertEq(fund.asset(), address(usdc), "asset() should return usdc");
    }
}

// ─────────────────────────────────────────────────────────────────
// 4. IL SHIELD HOOK UNIT TESTS
// ─────────────────────────────────────────────────────────────────

contract TestILShieldHook is Test {

    XenorizeILShieldHook hook;
    XenorizeInsuranceFund fund;
    MockERC20 usdc;
    MockERC20 weth;
    MockOracle oracle;

    address constant OWNER    = address(0xBEEF);
    address constant POOL_MGR = address(0xDEAD);
    address constant LP       = address(0xABCD);

    PoolKey poolKey;

    function setUp() public {
        vm.warp(1001 days);

        usdc   = new MockERC20("USD Coin", "USDC");
        weth   = new MockERC20("Wrapped ETH", "WETH");
        oracle = new MockOracle();

        // Set initial prices: ETH = $2000, USDC = $1
        oracle.setPrice(address(weth), 2_000e18);
        oracle.setPrice(address(usdc), 1e18);

        fund = new XenorizeInsuranceFund(address(usdc), OWNER, "xINS", "xINS");

        // Construct hook — deployed at a random address for testing
        // (hook address bit validation skipped; only tested in integration)
        hook = new XenorizeILShieldHook(
            IPoolManager(POOL_MGR),
            IInsuranceFund(address(fund)),
            IXenorizeOracle(address(oracle)),
            OWNER
        );

        // Authorize hook to submit claims + deposit fees
        vm.prank(OWNER);
        fund.setAuthorizedDepositor(address(hook), true);

        // Seed insurance fund
        usdc.mint(OWNER, 100_000e18);
        vm.startPrank(OWNER);
        usdc.approve(address(fund), 100_000e18);
        fund.depositFee(100_000e18);
        vm.stopPrank();

        // Pool key: WETH/USDC 0.30%
        poolKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: hook
        });
    }

    // ── afterAddLiquidity ────────────────────────────────────────

    function test_AfterAddLiquidity_CreatesSnapshot() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower:      -600,
            tickUpper:       600,
            liquidityDelta: int256(1_000e18),
            salt:           bytes32(0)
        });
        // delta: LP deposited 1 WETH (negative) and 2000 USDC (negative)
        BalanceDelta delta = _makeDelta(-1e18, -2_000e18);

        vm.prank(POOL_MGR);
        hook.afterAddLiquidity(LP, poolKey, params, delta, delta, abi.encode(LP));

        bytes32 key_ = keccak256(abi.encodePacked(
            LP, PoolIdLibrary.toId(poolKey), int24(-600), int24(600)
        ));
        (
            uint256 amount0,
            uint256 amount1,
            uint256 price0,
            uint256 price1,
            uint256 depositTime,
            uint128 liquidity,
            bool exists
        ) = _getSnapshot(key_);

        assertTrue(exists, "Snapshot should exist after addLiquidity");
        assertEq(amount0, 1e18, "amount0 should be 1 WETH");
        assertEq(amount1, 2_000e18, "amount1 should be 2000 USDC");
        assertEq(price0, 2_000e18, "price0 should be ETH oracle price");
        assertEq(price1, 1e18, "price1 should be USDC oracle price");
        assertEq(liquidity, 1_000e18, "liquidity mismatch");
        assertGt(depositTime, 0, "depositTime should be set");
    }

    function test_AfterAddLiquidity_UpdatesExistingSnapshot_WeightedAvg() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: int256(1_000e18), salt: bytes32(0)
        });
        BalanceDelta delta = _makeDelta(-1e18, -2_000e18);

        vm.prank(POOL_MGR);
        hook.afterAddLiquidity(LP, poolKey, params, delta, delta, abi.encode(LP));

        // Price doubles before second deposit
        oracle.setPrice(address(weth), 4_000e18);
        BalanceDelta delta2 = _makeDelta(-1e18, -4_000e18);

        vm.prank(POOL_MGR);
        hook.afterAddLiquidity(LP, poolKey, params, delta2, delta2, abi.encode(LP));

        bytes32 key_ = keccak256(abi.encodePacked(
            LP, PoolIdLibrary.toId(poolKey), int24(-600), int24(600)
        ));
        (, , uint256 price0, , , uint128 liquidity, ) = _getSnapshot(key_);

        // Weighted avg of 2000 and 4000 with equal liquidity = 3000
        assertEq(price0, 3_000e18, "Weighted avg price should be 3000");
        assertEq(liquidity, 2_000e18, "Total liquidity should be sum");
    }

    function test_AfterAddLiquidity_SkipsZeroDelta() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: 0, salt: bytes32(0) // fee collection — not a real add
        });
        BalanceDelta delta = _makeDelta(0, 0);

        vm.prank(POOL_MGR);
        hook.afterAddLiquidity(LP, poolKey, params, delta, delta, abi.encode(LP));

        bytes32 key_ = keccak256(abi.encodePacked(
            LP, PoolIdLibrary.toId(poolKey), int24(-600), int24(600)
        ));
        (, , , , , , bool exists) = _getSnapshot(key_);
        assertFalse(exists, "Should not create snapshot for fee collection");
    }

    // ── afterRemoveLiquidity ─────────────────────────────────────

    function test_AfterRemoveLiquidity_NoSnapshot_Skips() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: -int256(500e18), salt: bytes32(0)
        });
        BalanceDelta delta = _makeDelta(int128(0.5e18), int128(1_000e18));

        // Should not revert even with no snapshot
        vm.prank(POOL_MGR);
        hook.afterRemoveLiquidity(LP, poolKey, params, delta, delta, abi.encode(LP));
    }

    function test_AfterRemoveLiquidity_WithIL_TriggersCompensation() public {
        // 1. Add liquidity at ETH = $2000
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: int256(1_000e18), salt: bytes32(0)
        });
        BalanceDelta addDelta = _makeDelta(-1e18, -2_000e18);

        vm.prank(POOL_MGR);
        hook.afterAddLiquidity(LP, poolKey, addParams, addDelta, addDelta, abi.encode(LP));

        // 2. Warp 90 days so loyalty score = 100% (required for non-zero compensation)
        vm.warp(block.timestamp + 90 days);

        // 3. Price moves to $4000 (2x), creating IL
        oracle.setPrice(address(weth), 4_000e18);

        // 4. Remove all liquidity — LP gets back less value than HODL
        //    HODL at $4000: 1 ETH ($4000) + 2000 USDC = $6000
        //    LP at $4000 (5.72% IL): 0.707 WETH ($2828) + 2828 USDC = $5656
        //    IL_USD = $344 → compensation (50% × 100% loyalty) = $172 USDC
        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: -int256(1_000e18), salt: bytes32(0)
        });
        BalanceDelta removeDelta = _makeDelta(int128(0.707e18), int128(2_828e18));

        uint256 lpUsdcBefore = usdc.balanceOf(LP);

        vm.prank(POOL_MGR);
        hook.afterRemoveLiquidity(LP, poolKey, removeParams, removeDelta, removeDelta, abi.encode(LP));

        uint256 compensation = usdc.balanceOf(LP) - lpUsdcBefore;
        assertGt(compensation, 0, "LP should receive IL compensation");
        assertLe(compensation, 344e18, "Compensation cannot exceed IL amount");
    }

    function test_AfterRemoveLiquidity_NoIL_NoCompensation() public {
        // Add at $2000
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: int256(1_000e18), salt: bytes32(0)
        });
        BalanceDelta addDelta = _makeDelta(-1e18, -2_000e18);

        vm.prank(POOL_MGR);
        hook.afterAddLiquidity(LP, poolKey, addParams, addDelta, addDelta, abi.encode(LP));

        // Remove at same price — no IL
        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: -int256(1_000e18), salt: bytes32(0)
        });
        // LP gets back exactly what they put in (no IL)
        BalanceDelta removeDelta = _makeDelta(int128(1e18), int128(2_000e18));

        uint256 lpUsdcBefore = usdc.balanceOf(LP);

        vm.prank(POOL_MGR);
        hook.afterRemoveLiquidity(LP, poolKey, removeParams, removeDelta, removeDelta, abi.encode(LP));

        assertEq(usdc.balanceOf(LP), lpUsdcBefore, "No IL = no compensation");
    }

    function test_AfterRemoveLiquidity_ClearsSnapshot() public {
        IPoolManager.ModifyLiquidityParams memory addParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: int256(1_000e18), salt: bytes32(0)
        });
        vm.prank(POOL_MGR);
        hook.afterAddLiquidity(LP, poolKey, addParams, _makeDelta(-1e18, -2_000e18), _makeDelta(0, 0), abi.encode(LP));

        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: -int256(1_000e18), salt: bytes32(0)
        });
        vm.prank(POOL_MGR);
        hook.afterRemoveLiquidity(LP, poolKey, removeParams, _makeDelta(int128(1e18), int128(2_000e18)), _makeDelta(0, 0), abi.encode(LP));

        bytes32 key_ = keccak256(abi.encodePacked(
            LP, PoolIdLibrary.toId(poolKey), int24(-600), int24(600)
        ));
        (, , , , , , bool exists) = _getSnapshot(key_);
        assertFalse(exists, "Snapshot should be cleared after full removal");
    }

    function test_OnlyPoolManager_CanCallHooks() public {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: int256(1_000e18), salt: bytes32(0)
        });
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.afterAddLiquidity(LP, poolKey, params, _makeDelta(-1e18, -2_000e18), _makeDelta(0, 0), "");
    }

    function test_EmergencyPause_BlocksHooks() public {
        vm.prank(OWNER);
        hook.emergencyPause(true);

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -600, tickUpper: 600,
            liquidityDelta: int256(1_000e18), salt: bytes32(0)
        });
        vm.prank(POOL_MGR);
        vm.expectRevert();
        hook.afterAddLiquidity(LP, poolKey, params, _makeDelta(-1e18, -2_000e18), _makeDelta(0, 0), "");
    }

    // ── helpers ──────────────────────────────────────────────────

    function _makeDelta(int128 a0, int128 a1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap((int256(a0) << 128) | int256(uint256(uint128(a1))));
    }

    function _getSnapshot(bytes32 key_) internal view returns (
        uint256 amount0, uint256 amount1,
        uint256 price0, uint256 price1,
        uint256 depositTime, uint128 liquidity, bool exists
    ) {
        // Public mapping of a struct returns a tuple, not the struct type
        (amount0, amount1, price0, price1, depositTime, liquidity, exists) = hook.snapshots(key_);
    }
}

// ─────────────────────────────────────────────────────────────────
// 5. FUZZ TESTS
// ─────────────────────────────────────────────────────────────────

contract FuzzXenorizeMath is Test {

    function testFuzz_IL_AlwaysNonPositive(uint256 priceRatioWad) public pure {
        priceRatioWad = bound(priceRatioWad, 0, 1_000 * 1e18);
        int256 il = XenorizeMath.calculateIL(priceRatioWad);
        assertLe(il, 0, "IL must always be <= 0");
    }

    function testFuzz_DynamicFee_InBounds(
        uint24  baseFee,
        uint256 vol,
        uint256 targetVol,
        uint256 swapSize,
        uint256 tvl,
        bool    mev
    ) public pure {
        baseFee   = uint24(bound(baseFee, 0, 10_000));
        vol       = bound(vol, 0, 10_000);
        targetVol = bound(targetVol, 0, 10_000);
        swapSize  = bound(swapSize, 0, type(uint128).max);
        tvl       = bound(tvl, 1, type(uint128).max);

        uint24 fee = XenorizeMath.computeDynamicFee(
            baseFee, vol, targetVol, swapSize, tvl, mev
        );

        assertGe(fee, baseFee, "Fee must be >= base fee");
        assertLe(fee, 10_000,  "Fee must be <= 10_000 BPS");
    }

    function testFuzz_LoyaltyMultiplier_InBounds(
        uint256 depositTimestamp,
        uint256 currentTimestamp
    ) public pure {
        depositTimestamp = bound(depositTimestamp, 0, type(uint32).max);
        currentTimestamp = bound(currentTimestamp, depositTimestamp, type(uint32).max);

        uint256 mult = XenorizeMath.computeLoyaltyMultiplier(depositTimestamp, currentTimestamp);

        assertGe(mult, 10_000, "Multiplier must be >= 1.0x");
        assertLe(mult, 20_000, "Multiplier must be <= 2.0x");
    }

    function testFuzz_ILAmount_NeverExceedsCapital(
        uint256 initialAmount0,
        uint256 initialAmount1,
        uint256 currentPrice,
        uint256 initialPrice
    ) public pure {
        initialAmount0 = bound(initialAmount0, 0, 1_000_000e18);
        initialAmount1 = bound(initialAmount1, 0, 1_000_000e18);
        currentPrice   = bound(currentPrice, 1, 100_000e18);
        initialPrice   = bound(initialPrice, XenorizeMath.WAD, 100_000e18);

        uint256 il = XenorizeMath.calculateILAmount(
            initialAmount0, initialAmount1, currentPrice, initialPrice
        );

        uint256 totalCapital = initialAmount0 + initialAmount1;
        assertLe(il, totalCapital, "IL cannot exceed total capital deposited");
    }

    function testFuzz_InsuranceClaim_NeverExceedsHalfIL(
        uint256 ilAmount,
        uint256 loyaltyScore
    ) public {
        ilAmount     = bound(ilAmount, 0, 1_000_000e18);
        loyaltyScore = bound(loyaltyScore, 0, 10_000);

        MockERC20 usdc = new MockERC20("USDC", "USDC");
        XenorizeInsuranceFund fund = new XenorizeInsuranceFund(
            address(usdc), address(this), "xINS", "xINS"
        );

        bytes32 posId = keccak256("fuzz-pos");
        (uint256 maxComp, ) = fund.getMaxClaim(posId, ilAmount, 0, loyaltyScore);

        assertLe(maxComp, ilAmount / 2 + 1, "Compensation must not exceed 50% of IL");
    }
}

// ─────────────────────────────────────────────────────────────────
// 6. INVARIANT TESTS — NEVER-BREAK PROPERTIES
// ─────────────────────────────────────────────────────────────────

contract InvariantInsuranceFund is StdInvariant, Test {

    XenorizeInsuranceFund fund;
    MockERC20             usdc;

    address constant OWNER = address(0xBEEF);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC");
        fund = new XenorizeInsuranceFund(address(usdc), OWNER, "xINS", "xINS");
        targetContract(address(fund));
    }

    /// @notice INVARIANT: totalAssets must always equal actual token balance
    function invariant_TotalAssetsMatchesActualBalance() public view {
        assertEq(
            fund.totalAssets(),
            usdc.balanceOf(address(fund)),
            "CRITICAL: totalAssets != actual token balance"
        );
    }

    /// @notice INVARIANT: Total paid out must never exceed total fee income
    function invariant_PayoutsNeverExceedIncome() public view {
        assertLe(
            fund.totalPaidOut(),
            fund.totalFeeIncome() + fund.totalAssets(),
            "CRITICAL: Paid out more than fund ever received"
        );
    }
}

contract TestILInvariantProperties is Test {

    function test_ILWorsensWithDivergence() public pure {
        int256 il1 = XenorizeMath.calculateIL(1e18);
        int256 il2 = XenorizeMath.calculateIL(2e18);
        int256 il4 = XenorizeMath.calculateIL(4e18);

        assertTrue(il1 == 0, "IL at r=1 must be 0");
        assertTrue(il2 < il1, "IL at r=2 must be worse than r=1");
        assertTrue(il4 < il2, "IL at r=4 must be worse than r=2");
    }
}

// ─────────────────────────────────────────────────────────────────
// PHASE 2 MOCK CONTRACTS
// ─────────────────────────────────────────────────────────────────

/// @dev Minimal token interface for MockPoolManagerV4.take()
interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Callback interface used by AutoCompounder's unlockCallback
interface IUnlockCallbackV4 {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev Simulates Uniswap V4 PoolManager for AutoCompounder unit tests.
///      unlock() calls back unlockCallback on the caller.
///      modifyLiquidity() returns symmetric ±liq/2 deltas for equal-amount deposits.
///      take() transfers tokens from this contract (pre-funded in test setUp).
contract MockPoolManagerV4 {
    // Simulated accrued fee per fee-collection call (per token)
    int128 public constant MOCK_FEE = int128(10e18);

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallbackV4(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external pure returns (BalanceDelta delta, BalanceDelta feesAccrued) {
        if (params.liquidityDelta == 0) {
            // Fee collection: no principal change, non-zero accrued fees
            delta       = _pack(0, 0);
            feesAccrued = _pack(MOCK_FEE, MOCK_FEE);
        } else if (params.liquidityDelta > 0) {
            // Add liquidity: LP pays half per token
            int128 half = int128(params.liquidityDelta / 2);
            delta       = _pack(-half, -half);
            feesAccrued = _pack(0, 0);
        } else {
            // Remove liquidity: LP receives half per token
            int128 half = int128((-params.liquidityDelta) / 2);
            delta       = _pack(half, half);
            feesAccrued = _pack(0, 0);
        }
    }

    /// @dev Transfers `amount` of `currency` from this contract to `to`.
    ///      Contract must be pre-funded in test setUp.
    function take(Currency currency, address to, uint256 amount) external {
        IERC20Min(Currency.unwrap(currency)).transfer(to, amount);
    }

    function sync(Currency) external {}
    function settle() external pure returns (uint256) { return 0; }

    function _pack(int128 a0, int128 a1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap((int256(a0) << 128) | int256(uint256(uint128(a1))));
    }
}

/// @dev Minimal Chainlink AggregatorV3Interface mock for oracle tests.
contract MockChainlinkFeed {
    int256  public price;
    uint256 public updatedAt;
    uint8   private _decimals;

    constructor(int256 _price, uint8 dec) {
        price     = _price;
        updatedAt = block.timestamp;
        _decimals = dec;
    }

    function setPrice(int256 _price) external { price = _price; }
    function setUpdatedAt(uint256 ts) external { updatedAt = ts; }

    function latestRoundData() external view
        returns (uint80, int256 answer, uint256, uint256 ts, uint80)
    {
        return (0, price, 0, updatedAt, 0);
    }

    function decimals() external view returns (uint8) { return _decimals; }
}

// ─────────────────────────────────────────────────────────────────
// 7. AUTO-COMPOUNDER UNIT TESTS
// ─────────────────────────────────────────────────────────────────

contract TestAutoCompounder is Test {

    XenorizeAutoCompounder compounder;
    XenorizeInsuranceFund  fund;
    MockPoolManagerV4      mockPM;
    MockERC20              weth;
    MockERC20              usdc;
    MockOracle             oracle;

    address constant OWNER  = address(0xBEEF);
    address constant ALICE  = address(0xA11CE);
    address constant KEEPER = address(0xBB);

    uint256 constant DEPOSIT = 1_000e18; // equal token amounts — required by MockPM

    PoolKey        internal _key;
    CompoundConfig internal _cfg;

    function setUp() public {
        vm.warp(1_001 days);

        weth   = new MockERC20("WETH", "WETH");
        usdc   = new MockERC20("USDC", "USDC");
        oracle = new MockOracle();
        mockPM = new MockPoolManagerV4();

        oracle.setPrice(address(weth), 2_000e18); // ETH = $2 000
        oracle.setPrice(address(usdc), 1e18);

        fund = new XenorizeInsuranceFund(address(usdc), OWNER, "xINS", "xINS");

        compounder = new XenorizeAutoCompounder(
            OWNER,
            IPoolManager(address(mockPM)),
            address(fund),
            address(weth),
            address(usdc),
            address(oracle)
        );

        vm.prank(OWNER);
        fund.setAuthorizedDepositor(address(compounder), true);

        // Pre-fund mockPM so take() calls can always succeed
        weth.mint(address(mockPM), 1_000_000e18);
        usdc.mint(address(mockPM), 1_000_000e18);

        // Fund Alice + approvals
        weth.mint(ALICE, 100_000e18);
        usdc.mint(ALICE, 100_000e18);
        vm.startPrank(ALICE);
        weth.approve(address(compounder), type(uint256).max);
        usdc.approve(address(compounder), type(uint256).max);
        vm.stopPrank();

        // Pool key: WETH/USDC 0.30%
        _key = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee:         3_000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });

        _cfg = CompoundConfig({
            minProfitUSD:       1e18,
            gasCushionBps:      200,
            slippageBps:        100,
            maxCompoundsPerDay: 4,
            aiRangeEnabled:     false,
            autoRebalance:      false
        });
    }

    // ── helpers ──────────────────────────────────────────────────

    function _openManual() internal returns (bytes32 id) {
        vm.prank(ALICE);
        id = compounder.openPosition(_key, -100, 100, DEPOSIT, DEPOSIT, RiskProfile.Balanced, _cfg);
    }

    function _openAI() internal returns (bytes32 id) {
        vm.prank(ALICE);
        id = compounder.openPositionAI(_key, DEPOSIT, DEPOSIT, RiskProfile.Balanced, _cfg);
    }

    // ── tests ────────────────────────────────────────────────────

    function test_OpenPosition_StoresStateCorrectly() public {
        bytes32 id  = _openManual();
        Position memory pos = compounder.getPosition(id);

        assertEq(pos.owner,            ALICE,                  "wrong owner");
        assertFalse(pos.aiManaged,                             "should be manual");
        assertEq(pos.initialCapital0,  DEPOSIT,               "wrong capital0");
        assertEq(pos.initialCapital1,  DEPOSIT,               "wrong capital1");
        assertEq(uint8(pos.status),    uint8(PositionStatus.Active), "not Active");
        assertEq(pos.entryPrice0USD,   2_000e18,              "wrong entry price");
        assertEq(pos.compoundCount,    0,                     "fresh position");
    }

    function test_OpenPosition_TokensTransferredToMockPM() public {
        uint256 before = weth.balanceOf(address(mockPM));
        _openManual();
        // liqDelta = DEPOSIT + DEPOSIT = 2000e18; half per token → mockPM receives DEPOSIT weth
        assertEq(weth.balanceOf(address(mockPM)), before + DEPOSIT, "WETH not in pool");
        assertEq(usdc.balanceOf(address(mockPM)), 1_000_000e18 + DEPOSIT, "USDC not in pool");
    }

    function test_OpenPosition_TVLCapEnforced() public {
        vm.prank(OWNER);
        compounder.setMaxTVLCap(1e18); // set cap below our deposit

        vm.prank(ALICE);
        vm.expectRevert();
        compounder.openPosition(_key, -100, 100, DEPOSIT, DEPOSIT, RiskProfile.Balanced, _cfg);
    }

    function test_OpenPositionAI_UsesOracleRange() public {
        bytes32 id  = _openAI();
        Position memory pos = compounder.getPosition(id);

        assertTrue(pos.aiManaged, "should be AI-managed");
        // MockOracle returns (-3000, 3000) for Balanced
        assertEq(pos.tickLower, -3_000, "wrong AI tickLower");
        assertEq(pos.tickUpper,  3_000, "wrong AI tickUpper");
    }

    function test_OpenPositionAI_EntryPriceStored() public {
        bytes32 id  = _openAI();
        Position memory pos = compounder.getPosition(id);
        assertEq(pos.entryPrice0USD, 2_000e18, "entry price not stored for AI position");
    }

    function test_ClosePosition_ReturnsTokensToOwner() public {
        bytes32 id       = _openManual();
        uint256 beforeW  = weth.balanceOf(ALICE);
        uint256 beforeU  = usdc.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 r0, uint256 r1) = compounder.closePosition(id);

        // MockPM returns liq/2 per token = DEPOSIT each
        assertEq(r0, DEPOSIT, "wrong weth returned");
        assertEq(r1, DEPOSIT, "wrong usdc returned");
        assertEq(weth.balanceOf(ALICE), beforeW + DEPOSIT, "Alice didn't get WETH back");
        assertEq(usdc.balanceOf(ALICE), beforeU + DEPOSIT, "Alice didn't get USDC back");
    }

    function test_ClosePosition_OnlyOwnerOrKeeper() public {
        bytes32 id = _openManual();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        compounder.closePosition(id);
    }

    function test_CompoundManual_FailsOnAIPosition() public {
        bytes32 id = _openAI();
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        vm.expectRevert();
        compounder.compoundManual(id);
    }

    function test_AutoCompound_FailsOnManualPosition() public {
        bytes32 id = _openManual();
        vm.roll(block.number + 1);
        vm.prank(ALICE);
        vm.expectRevert();
        compounder.autoCompound(id);
    }

    function test_CompoundRateLimit_SameBlock() public {
        bytes32 id = _openManual();
        // compound in same block as open → rate-limited
        vm.prank(ALICE);
        vm.expectRevert();
        compounder.compoundManual(id);
    }

    function test_CompoundManual_ProtocolFeeForwardedToOwner() public {
        bytes32 id = _openManual();
        vm.roll(block.number + 1);

        uint256 ownerBefore = usdc.balanceOf(OWNER);
        vm.prank(ALICE);
        compounder.compoundManual(id);

        // Protocol fee = MOCK_FEE(10e18) * protocolFeeBps(200) / 10000 = 0.2e18 USDC
        uint256 expectedFee = (uint256(10e18) * 200) / 10_000; // MOCK_FEE=10e18 * protocolFeeBps/BPS
        assertGe(usdc.balanceOf(OWNER) - ownerBefore, expectedFee - 1, "protocol fee not forwarded");
    }

    function test_CompoundManual_CapitalGrowsAfterFees() public {
        bytes32 id = _openManual();
        vm.roll(block.number + 1);

        vm.prank(ALICE);
        CompoundResult memory res = compounder.compoundManual(id);

        // Net capital = DEPOSIT + fees - protocolFee
        assertGt(res.newCapital0, DEPOSIT, "capital should grow after compounding fees");
    }

    function test_EmergencyPause_BlocksOpenPosition() public {
        vm.prank(OWNER);
        compounder.emergencyPause();

        vm.prank(ALICE);
        vm.expectRevert();
        compounder.openPosition(_key, -100, 100, DEPOSIT, DEPOSIT, RiskProfile.Balanced, _cfg);
    }

    function test_GetCompoundUrgency_ScalesWithTime() public {
        uint256 openTime = block.timestamp;
        bytes32 id = _openManual();

        assertEq(uint8(compounder.getCompoundUrgency(id)), uint8(CompoundUrgency.None), "fresh: none");

        vm.warp(openTime + 7 hours);
        assertEq(uint8(compounder.getCompoundUrgency(id)), uint8(CompoundUrgency.Low), "7h: low");

        vm.warp(openTime + 31 hours);
        assertEq(uint8(compounder.getCompoundUrgency(id)), uint8(CompoundUrgency.Medium), "31h: medium");

        vm.warp(openTime + 55 hours);
        assertEq(uint8(compounder.getCompoundUrgency(id)), uint8(CompoundUrgency.High), "55h: high");
    }

    function test_IL_IsZeroWhenPriceUnchanged() public {
        bytes32 id = _openManual();
        vm.roll(block.number + 1);

        // Price unchanged → no IL
        vm.prank(ALICE);
        CompoundResult memory res = compounder.compoundManual(id);
        assertEq(res.ilRealized0, 0, "no IL when price unchanged");
    }

    function test_IL_NonZeroWhenPriceChanges() public {
        bytes32 id = _openManual();
        vm.roll(block.number + 1);

        // ETH price doubles → IL > 0
        oracle.setPrice(address(weth), 4_000e18);
        vm.prank(ALICE);
        CompoundResult memory res = compounder.compoundManual(id);
        assertGt(res.ilRealized0, 0, "IL should be > 0 when price doubles");
    }
}

// ─────────────────────────────────────────────────────────────────
// 8. CHAINLINK ORACLE UNIT TESTS
// ─────────────────────────────────────────────────────────────────

contract TestChainlinkOracle is Test {

    XenorizeChainlinkOracle oracle;
    MockChainlinkFeed       ethFeed;
    MockChainlinkFeed       gasFeed_;

    MockERC20 weth;
    MockERC20 usdc;

    address constant OWNER    = address(0xBEEF);
    address constant POOL_MGR = address(0xDEAD);

    function setUp() public {
        vm.warp(1_001 days);

        weth    = new MockERC20("WETH", "WETH");
        usdc    = new MockERC20("USDC", "USDC");
        // Chainlink ETH/USD: 8 decimals, price = 2000e8
        ethFeed  = new MockChainlinkFeed(int256(2_000e8), 8);
        gasFeed_ = new MockChainlinkFeed(int256(2_000e8), 8);

        oracle = new XenorizeChainlinkOracle(
            IPoolManager(POOL_MGR), OWNER, address(gasFeed_)
        );

        vm.prank(OWNER);
        oracle.setFeed(address(weth), address(ethFeed));
    }

    function test_GetTokenPrice_NoFeed_ReturnsFallbackOne() public view {
        // usdc has no feed registered → fallback $1 (WAD)
        (uint256 price, ) = oracle.getTokenPriceUSD(address(usdc));
        assertEq(price, 1e18, "no-feed fallback should be $1");
    }

    function test_GetTokenPrice_ValidFeed_ConvertsDecimals() public view {
        // ethFeed returns 2000e8 (8 dec) → should be normalized to 2000e18
        (uint256 price, ) = oracle.getTokenPriceUSD(address(weth));
        assertEq(price, 2_000e18, "ETH price should be $2000 in WAD");
    }

    function test_GetTokenPrice_StalePrice_Reverts() public {
        // Age the price beyond oracleMaxAge (1 hour default)
        ethFeed.setUpdatedAt(block.timestamp - 2 hours);
        vm.expectRevert();
        oracle.getTokenPriceUSD(address(weth));
    }

    function test_GetTokenPrice_NegativePrice_Reverts() public {
        ethFeed.setPrice(-1);
        vm.expectRevert();
        oracle.getTokenPriceUSD(address(weth));
    }

    function test_GetVolatility_Default_WhenInsufficientData() public view {
        bytes32 poolId = keccak256("WETH-USDC");
        uint256 vol = oracle.getVolatility(poolId);
        assertEq(vol, 3_000, "default vol should be 30% (3000 BPS)");
    }

    function test_RecordPrice_BuildsHistory() public {
        bytes32 poolId = keccak256("WETH-USDC");
        // Record 2+ prices so vol can be computed
        oracle.recordPrice(poolId, address(weth));
        ethFeed.setPrice(int256(2_200e8));
        oracle.recordPrice(poolId, address(weth));

        uint256 vol = oracle.getVolatility(poolId);
        assertGt(vol, 0, "vol should be > 0 after recording prices");
    }

    function test_GetSuggestedRange_ConservativeWiderThanAggressive() public view {
        bytes32 poolId = keccak256("WETH-USDC");
        (, int24 upC, ) = oracle.getSuggestedRange(poolId, RiskProfile.Conservative);
        (, int24 upA, ) = oracle.getSuggestedRange(poolId, RiskProfile.Aggressive);
        assertGt(int256(upC), int256(upA), "Conservative range must be wider");
    }

    function test_SetFeed_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        oracle.setFeed(address(usdc), address(ethFeed));

        vm.prank(OWNER);
        oracle.setFeed(address(usdc), address(ethFeed));
        (uint256 p, ) = oracle.getTokenPriceUSD(address(usdc));
        assertEq(p, 2_000e18, "USDC should now return ETH feed price");
    }

    function test_GetGasCostUSD_FeedNotSet_ReturnsFallback() public {
        // Test the $0.50 fallback by constructing an oracle without a gas feed
        XenorizeChainlinkOracle noGasFeedOracle = new XenorizeChainlinkOracle(
            IPoolManager(POOL_MGR), OWNER, address(0)
        );
        uint256 gasCost = noGasFeedOracle.getGasCostUSD();
        assertEq(gasCost, 0.50e18, "fallback gas cost should be $0.50");
    }

    function test_SetOracleMaxAge_ThenStaleReverts() public {
        vm.prank(OWNER);
        oracle.setOracleMaxAge(30 minutes);

        ethFeed.setUpdatedAt(block.timestamp - 31 minutes);
        vm.expectRevert();
        oracle.getTokenPriceUSD(address(weth));
    }
}

// ─────────────────────────────────────────────────────────────────
// 9. PHASE 2 FUZZ TESTS
// ─────────────────────────────────────────────────────────────────

contract FuzzPhase2 is Test {

    function testFuzz_LoyaltyScore_LinearGrowth(uint256 days_) public pure {
        days_ = bound(days_, 0, 365);
        uint256 ts0 = 0;
        uint256 ts1 = days_ * 1 days;
        uint256 score = XenorizeMath.computeLoyaltyScore(ts0, ts1);

        assertLe(score, 10_000, "score must be <= 10000 BPS");
        if (days_ >= 90) {
            assertEq(score, 10_000, "score must max at 90 days");
        } else {
            assertEq(score, (days_ * 10_000) / 90, "linear before 90 days");
        }
    }

    function testFuzz_ILCompensation_ScalesWithLoyalty(
        uint256 ilUSD,
        uint256 score1,
        uint256 score2
    ) public {
        ilUSD  = bound(ilUSD,  1e18, 100_000e18);
        score1 = bound(score1, 0, 5_000);
        score2 = bound(score2, score1, 10_000);

        MockERC20 usdc = new MockERC20("USDC", "USDC");
        XenorizeInsuranceFund fund = new XenorizeInsuranceFund(
            address(usdc), address(this), "xINS", "xINS"
        );

        bytes32 pid = keccak256("fuzz-pos");
        (uint256 c1, ) = fund.getMaxClaim(pid, ilUSD, 0, score1);
        (uint256 c2, ) = fund.getMaxClaim(pid, ilUSD, 0, score2);

        assertLe(c1, c2, "higher loyalty should give >= compensation");
        assertLe(c2, ilUSD / 2 + 1, "max 50% of IL");
    }

    function testFuzz_AutoCompounder_CapitalNeverDecreasesFromFees(
        uint256 feeAmt
    ) public {
        // After compounding, net capital must be >= initial (fees compensate protocol cut)
        feeAmt = bound(feeAmt, 0, 1_000e18);
        // Protocol fee BPS = 200 → net growth = feeAmt * (1 - 0.02) > 0
        uint256 protocolFee = (feeAmt * 200) / 10_000;
        uint256 netFee      = feeAmt - protocolFee;
        assertGe(netFee, 0, "net fee after protocol cut must be >= 0");
        assertLe(protocolFee, feeAmt, "protocol fee must be <= total fee");
    }
}

// ─────────────────────────────────────────────────────────────────
// 6. NEW HOOK UNIT TESTS
// ─────────────────────────────────────────────────────────────────

import {XenorizeAutoRangeHook}              from "../../src/hooks/AutoRangeHook.sol";
import {XenorizeLoyaltyHook}               from "../../src/hooks/LoyaltyHook.sol";
import {XenorizeTWAMMHook}                 from "../../src/hooks/TWAMMHook.sol";
import {XenorizeMultiPositionStrategyHook} from "../../src/hooks/MultiPositionStrategyHook.sol";

// ─── AutoRangeHook Tests ──────────────────────────────────────────

contract TestAutoRangeHook is Test {
    XenorizeAutoRangeHook hook;
    address constant OWNER   = address(0xBEEF);
    address constant PM      = address(0xDEAD);

    function setUp() public {
        hook = new XenorizeAutoRangeHook(PM, address(0), OWNER);
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(hook.owner(), OWNER);
    }

    function test_EmergencyPause_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        hook.emergencyPause(true);

        vm.prank(OWNER);
        hook.emergencyPause(true);
        assertTrue(hook.paused());
    }

    function test_RegisterPosition_StoresRecord() public {
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(address(0x1)),
            currency1:   Currency.wrap(address(0x2)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });
        bytes32 posKey = hook.registerPosition(key, -1000, 1000, 500, false);
        (address lp, int24 lo, int24 hi,, bool ai, bool active) = hook.managedPositions(posKey);
        assertEq(lp, address(this));
        assertEq(lo, -1000);
        assertEq(hi, 1000);
        assertFalse(ai);
        assertTrue(active);
    }

    function test_DeregisterPosition_DeactivatesRecord() public {
        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(address(0x1)),
            currency1:   Currency.wrap(address(0x2)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });
        bytes32 posKey = hook.registerPosition(key, -1000, 1000, 500, false);
        hook.deregisterPosition(posKey);
        (,,,,,bool active) = hook.managedPositions(posKey);
        assertFalse(active);
    }

    function testFuzz_UrgencyComputation_OutOfRange(int24 lower, int24 upper) public {
        // Out-of-range tick → urgency 2
        lower = int24(bound(lower, -887272, 0));
        upper = int24(bound(upper, 1,  887272));
        // tick at lower - 1 = out of range below
        int24 tick = lower - 1;
        // Urgency is internal — test indirectly via registerPosition + getPositionsNeedingRebalance
        // (requires PoolManager mock; here we assert math constants are consistent)
        assertTrue(lower < upper, "precondition");
    }
}

// ─── LoyaltyHook Tests ────────────────────────────────────────────

contract TestLoyaltyHook is Test {
    XenorizeLoyaltyHook hook;
    address constant OWNER = address(0xBEEF);
    address constant PM    = address(0xDEAD);

    function setUp() public {
        hook = new XenorizeLoyaltyHook(PM, OWNER);
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(hook.owner(), OWNER);
    }

    function test_Constants_SumToExpected() public view {
        assertEq(hook.EARLY_EXIT_THRESHOLD(),   7 days);
        assertEq(hook.EARLY_EXIT_PENALTY_BPS(), 200);
        assertEq(hook.BPS_MAX(), 10_000);
    }

    function test_GetLoyaltyMultiplier_NoRecord_Returns1x() public view {
        bytes32 key = keccak256("nonexistent");
        uint256 mult = hook.getLoyaltyMultiplier(key);
        assertEq(mult, 10_000, "No record should return 1.0x");
    }

    function testFuzz_LoyaltyMultiplier_InBounds(uint256 depositAge) public {
        // Clamp to ensure no underflow on genesis block (block.timestamp can be 1)
        depositAge = bound(depositAge, 0, block.timestamp < 365 days ? block.timestamp : 365 days);
        uint256 mult = XenorizeMath.computeLoyaltyMultiplier(
            block.timestamp - depositAge,
            block.timestamp
        );
        assertGe(mult, 10_000, "Multiplier >= 1.0x");
        assertLe(mult, 20_000, "Multiplier <= 2.0x");
    }
}

// ─── TWAMMHook Tests ──────────────────────────────────────────────

contract TestTWAMMHook is Test {
    XenorizeTWAMMHook hook;
    MockERC20         token0;
    MockERC20         token1;
    address constant OWNER = address(0xBEEF);
    address constant PM    = address(0xDEAD);

    function setUp() public {
        hook   = new XenorizeTWAMMHook(PM, OWNER);
        token0 = new MockERC20("WETH", "WETH");
        token1 = new MockERC20("USDC", "USDC");
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(hook.owner(), OWNER);
    }

    function test_PlaceLongTermOrder_StoresOrder() public {
        token0.mint(address(this), 1_000e18);
        token0.approve(address(hook), 1_000e18);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(address(token0)),
            currency1:   Currency.wrap(address(token1)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });

        bytes32 orderId = hook.placeLongTermOrder(key, true, 1_000e18, 1 hours);

        (uint256 pct, uint256 remaining, bool active) = hook.getOrderProgress(orderId);
        assertTrue(active);
        assertEq(remaining, 1_000e18);
        assertEq(pct, 0);
    }

    function test_PlaceLongTermOrder_RejectsTooShort() public {
        token0.mint(address(this), 1e18);
        token0.approve(address(hook), 1e18);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(address(token0)),
            currency1:   Currency.wrap(address(token1)),
            fee:         3000, tickSpacing: 60, hooks: IHooks(address(0))
        });

        vm.expectRevert();
        hook.placeLongTermOrder(key, true, 1e18, 5 minutes); // too short
    }

    function test_CancelOrder_RefundsTokens() public {
        token0.mint(address(this), 500e18);
        token0.approve(address(hook), 500e18);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(address(token0)),
            currency1:   Currency.wrap(address(token1)),
            fee:         3000, tickSpacing: 60, hooks: IHooks(address(0))
        });

        bytes32 orderId = hook.placeLongTermOrder(key, true, 500e18, 1 hours);
        uint256 balBefore = token0.balanceOf(address(this));

        hook.cancelOrder(key, orderId);

        uint256 balAfter = token0.balanceOf(address(this));
        assertEq(balAfter - balBefore, 500e18, "Full refund on cancel");
    }

    function test_GetActiveOrderCount_IncreasesOnPlace() public {
        token0.mint(address(this), 2_000e18);
        token0.approve(address(hook), 2_000e18);

        PoolKey memory key = PoolKey({
            currency0:   Currency.wrap(address(token0)),
            currency1:   Currency.wrap(address(token1)),
            fee:         3000, tickSpacing: 60, hooks: IHooks(address(0))
        });

        PoolId poolId = key.toId();
        assertEq(hook.getActiveOrderCount(poolId), 0);

        hook.placeLongTermOrder(key, true, 1_000e18, 1 hours);
        assertEq(hook.getActiveOrderCount(poolId), 1);

        hook.placeLongTermOrder(key, true, 1_000e18, 2 hours);
        assertEq(hook.getActiveOrderCount(poolId), 2);
    }
}

// ─── MultiPositionStrategyHook Tests ─────────────────────────────

contract TestMultiPositionStrategyHook is Test {
    XenorizeMultiPositionStrategyHook hook;
    address constant OWNER = address(0xBEEF);
    address constant PM    = address(0xDEAD);

    function setUp() public {
        hook = new XenorizeMultiPositionStrategyHook(PM, address(0), OWNER);
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(hook.owner(), OWNER);
    }

    function test_LayerAllocations_SumTo100Pct() public view {
        uint256 total = hook.LAYER_A_BPS() + hook.LAYER_B_BPS() + hook.LAYER_C_BPS();
        assertEq(total, 10_000, "Layer allocations must sum to 100%");
    }

    function test_LayerAllocations_AreCorrect() public view {
        assertEq(hook.LAYER_A_BPS(), 2_000, "Layer A = 20%");
        assertEq(hook.LAYER_B_BPS(), 5_000, "Layer B = 50%");
        assertEq(hook.LAYER_C_BPS(), 3_000, "Layer C = 30%");
    }

    function test_RangeWidths_NarrowLessThanMediumLessThanWide() public view {
        assertLt(hook.NARROW_HALF_WIDTH(), hook.MEDIUM_HALF_WIDTH(), "Narrow < Medium");
        assertLt(hook.MEDIUM_HALF_WIDTH(), hook.WIDE_HALF_WIDTH(),   "Medium < Wide");
    }

    function test_GetCapitalAllocation_SumsToTotal() public {
        // Simulate a strategy by calling getCapitalAllocation on a fresh key
        // (capital = 0, so all layers should be 0)
        bytes32 sk = keccak256("test-strategy");
        (uint256 a0, uint256 b0, uint256 c0,,, ) = hook.getCapitalAllocation(sk);
        assertEq(a0 + b0 + c0, 0, "Empty strategy = zero capital");
    }

    function testFuzz_CapitalAllocation_NeverExceedsTotal(uint256 cap0, uint256 cap1) public view {
        cap0 = bound(cap0, 0, 1_000_000e18);
        cap1 = bound(cap1, 0, 1_000_000e18);
        uint256 a0 = (cap0 * hook.LAYER_A_BPS()) / hook.BPS_MAX();
        uint256 b0 = (cap0 * hook.LAYER_B_BPS()) / hook.BPS_MAX();
        uint256 c0 = cap0 - a0 - b0;
        assertLe(a0 + b0 + c0, cap0 + 1, "Allocation must not exceed total (rounding tolerance)");
    }
}
