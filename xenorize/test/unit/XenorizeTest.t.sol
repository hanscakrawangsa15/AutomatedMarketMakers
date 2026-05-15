// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {XenorizeDynamicFeeHook} from "../../src/hooks/DynamicFeeHook.sol";
import {InsuranceClaim, RiskProfile} from "../../src/types/XenorizeTypes.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

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
        // Ensure block.timestamp is large enough for all loyalty duration tests
        vm.warp(1001 days);
    }

    // ─── IL Calculation Tests ─────────────────────────────────────

    function test_IL_ZeroPriceRatio_Returns100PercentLoss() public pure {
        // If price goes to 0, IL should be -100%
        int256 il = XenorizeMath.calculateIL(0);
        assertEq(il, -int256(XenorizeMath.WAD), "Zero price = 100% loss");
    }

    function test_IL_NoPriceChange_ReturnsZero() public pure {
        // If price doesn't change (r = 1), IL = 0
        int256 il = XenorizeMath.calculateIL(XenorizeMath.WAD);
        assertEq(il, 0, "No price change = no IL");
    }

    function test_IL_2xPriceIncrease_Returns572BPS() public pure {
        // ETH doubles: r = 2, IL ≈ -5.72%
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
        // IL should be symmetric: 2x up ≈ 0.5x down (same percentage loss)
        uint256 up   = 2 * XenorizeMath.WAD;
        uint256 down = XenorizeMath.WAD / 2;

        int256 ilUp   = XenorizeMath.calculateIL(up);
        int256 ilDown = XenorizeMath.calculateIL(down);

        uint256 diff = ilUp > ilDown
            ? uint256(ilUp - ilDown)
            : uint256(ilDown - ilUp);

        assertLt(diff, 0.01e18, "IL not symmetric for equal up/down moves");
    }

    // ─── Dynamic Fee Tests ────────────────────────────────────────

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

    // ─── Loyalty Multiplier Tests ─────────────────────────────────

    function test_LoyaltyMultiplier_Day0_Returns1x() public view {
        uint256 mult = XenorizeMath.computeLoyaltyMultiplier(
            block.timestamp, block.timestamp
        );
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

    // ─── Sqrt Tests ───────────────────────────────────────────────

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

        // Cannot execute before timelock
        vm.prank(OWNER);
        vm.expectRevert();
        hook.executeOracleUpdate(newOracle);

        // After timelock, can execute
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(OWNER);
        hook.executeOracleUpdate(newOracle);
        assertEq(address(hook.oracle()), newOracle);
    }
}

// ─────────────────────────────────────────────────────────────────
// 3. INSURANCE FUND UNIT TESTS
// ─────────────────────────────────────────────────────────────────

contract TestInsuranceFund is Test {

    XenorizeInsuranceFund fund;
    MockERC20             usdc;
    MockERC20             weth;

    address constant OWNER      = address(0xBEEF);
    address constant COMPOUNDER = address(0xC0C0);

    function setUp() public {
        usdc = new MockERC20("USD Coin",    "USDC");
        weth = new MockERC20("Wrapped ETH", "WETH");
        fund = new XenorizeInsuranceFund(OWNER, COMPOUNDER, address(usdc), address(weth));
    }

    function test_Deposit_UpdatesBalance() public {
        vm.prank(OWNER);
        fund.setAuthorizedDepositor(address(this), true);
        usdc.mint(address(this), 1_000e18);
        usdc.approve(address(fund), 1_000e18);
        fund.deposit(1_000e18, 0);
        assertEq(fund.fundBalance0(), 1_000e18);
    }

    function test_Deposit_OnlyAuthorized() public {
        usdc.mint(address(this), 100e18);
        usdc.approve(address(fund), 100e18);
        vm.expectRevert();
        fund.deposit(100e18, 0);
    }

    function test_GetMaxClaim_RespectsCap50Percent() public view {
        bytes32 posId    = keccak256("pos1");
        uint256 ilAmount = 1_000e18;
        (uint256 max0,)  = fund.getMaxClaim(posId, ilAmount, 0, 10_000);
        assertLe(max0, ilAmount / 2, "Claim cannot exceed 50% of IL");
    }

    function test_GetMaxClaim_LoyaltyScalesPayout() public view {
        bytes32 posId    = keccak256("pos1");
        uint256 ilAmount = 1_000e18;
        (uint256 max0Low,)  = fund.getMaxClaim(posId, ilAmount, 0, 0);
        (uint256 max0High,) = fund.getMaxClaim(posId, ilAmount, 0, 10_000);
        assertEq(max0Low, 0, "0 loyalty = 0 claim");
        assertGt(max0High, max0Low, "100% loyalty > 0% loyalty");
    }

    function test_EmergencyPause_StopsClaims() public {
        vm.prank(OWNER);
        fund.emergencyPause();

        InsuranceClaim memory claim = InsuranceClaim({
            positionId:   keccak256("pos1"),
            ilAmount0:    100e18,
            ilAmount1:    0,
            loyaltyScore: 10_000,
            proof:        ""
        });

        vm.prank(COMPOUNDER);
        vm.expectRevert();
        fund.submitClaim(claim);
    }

    function test_OnlyOwnerCanPause() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        fund.emergencyPause();

        vm.prank(OWNER);
        fund.emergencyPause();
        assertTrue(fund.paused());
    }
}

// ─────────────────────────────────────────────────────────────────
// 4. FUZZ TESTS
// ─────────────────────────────────────────────────────────────────

contract FuzzXenorizeMath is Test {

    /// @dev IL should always be <= 0 for any price ratio
    function testFuzz_IL_AlwaysNonPositive(uint256 priceRatioWad) public pure {
        priceRatioWad = bound(priceRatioWad, 0, 1_000 * 1e18);
        int256 il = XenorizeMath.calculateIL(priceRatioWad);
        assertLe(il, 0, "IL must always be <= 0");
    }

    /// @dev Dynamic fee should always be within [baseFee, 10_000]
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

    /// @dev Loyalty multiplier should always be in [10_000, 20_000]
    function testFuzz_LoyaltyMultiplier_InBounds(
        uint256 depositTimestamp,
        uint256 currentTimestamp
    ) public pure {
        depositTimestamp = bound(depositTimestamp, 0, type(uint32).max);
        currentTimestamp = bound(currentTimestamp, depositTimestamp, type(uint32).max);

        uint256 mult = XenorizeMath.computeLoyaltyMultiplier(
            depositTimestamp, currentTimestamp
        );

        assertGe(mult, 10_000, "Multiplier must be >= 1.0x");
        assertLe(mult, 20_000, "Multiplier must be <= 2.0x");
    }

    /// @dev IL amount in token0 must not exceed total initial capital
    /// @dev initialPrice bounded >= WAD to keep totalValue0 <= a0 + a1
    function testFuzz_ILAmount_NeverExceedsCapital(
        uint256 initialAmount0,
        uint256 initialAmount1,
        uint256 currentPrice,
        uint256 initialPrice
    ) public pure {
        initialAmount0 = bound(initialAmount0, 0, 1_000_000e18);
        initialAmount1 = bound(initialAmount1, 0, 1_000_000e18);
        currentPrice   = bound(currentPrice, 1, 100_000e18);
        // Bound initialPrice >= WAD so (a1 * WAD / initialPrice) <= a1
        initialPrice   = bound(initialPrice, XenorizeMath.WAD, 100_000e18);

        uint256 il = XenorizeMath.calculateILAmount(
            initialAmount0, initialAmount1, currentPrice, initialPrice
        );

        uint256 totalCapital = initialAmount0 + initialAmount1;
        assertLe(il, totalCapital, "IL cannot exceed total capital deposited");
    }
}

// ─────────────────────────────────────────────────────────────────
// 5. INVARIANT TESTS — NEVER-BREAK PROPERTIES
// ─────────────────────────────────────────────────────────────────

contract InvariantInsuranceFund is StdInvariant, Test {

    XenorizeInsuranceFund fund;
    MockERC20             usdc;
    MockERC20             weth;

    address constant OWNER      = address(0xBEEF);
    address constant COMPOUNDER = address(0xC0C0);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC");
        weth = new MockERC20("WETH", "WETH");
        fund = new XenorizeInsuranceFund(OWNER, COMPOUNDER, address(usdc), address(weth));
        targetContract(address(fund));
    }

    /// @notice INVARIANT: Fund balance must always equal real token balance
    function invariant_FundBalanceMatchesActualBalance() public view {
        assertEq(
            fund.fundBalance0(),
            usdc.balanceOf(address(fund)),
            "CRITICAL: Fund balance != actual token balance"
        );
    }

    /// @notice INVARIANT: Total paid out must never exceed total deposited
    function invariant_PayoutsNeverExceedDeposits() public view {
        assertLe(
            fund.totalPaidOut0(),
            fund.totalDeposited0(),
            "CRITICAL: Paid out more than deposited"
        );
    }
}

contract TestILInvariantProperties is Test {

    /// @notice IL is always monotonically more severe as price diverges
    function test_ILWorsensWithDivergence() public pure {
        int256 il1 = XenorizeMath.calculateIL(1e18);
        int256 il2 = XenorizeMath.calculateIL(2e18);
        int256 il4 = XenorizeMath.calculateIL(4e18);

        assertTrue(il1 == 0, "IL at r=1 must be 0");
        assertTrue(il2 < il1, "IL at r=2 must be worse than r=1");
        assertTrue(il4 < il2, "IL at r=4 must be worse than r=2");
    }
}
