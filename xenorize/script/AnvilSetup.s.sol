// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager}     from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey}          from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta}     from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency}         from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback}  from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20}           from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {XenorizeInsuranceFund}   from "../src/core/InsuranceFund.sol";
import {XenorizeAutoCompounder}  from "../src/core/AutoCompounder.sol";
import {XenorizeDynamicFeeHook}  from "../src/hooks/DynamicFeeHook.sol";
import {XenorizeChainlinkOracle} from "../src/oracles/XenorizeChainlinkOracle.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockPoolManager — simulates Uniswap V4 PoolManager for local Anvil testing.
//
// Protocol:
//   unlock(data)                     → calls unlockCallback(data) on caller
//   modifyLiquidity(liqDelta > 0)    → negative delta (caller pays pool)
//   modifyLiquidity(liqDelta < 0)    → positive delta (pool pays caller via take)
//   modifyLiquidity(liqDelta == 0)   → feesAccrued = (FEE_AMOUNT, FEE_AMOUNT)
//   take(currency, to, amt)          → ERC-20 transfer from this contract to `to`
//   sync / settle                    → no-ops
// ─────────────────────────────────────────────────────────────────────────────
contract MockPoolManager {
    int128 public constant FEE_AMOUNT = int128(10e18); // simulated fee per collect

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) external pure returns (BalanceDelta delta, BalanceDelta feesAccrued) {
        if (params.liquidityDelta == 0) {
            // Collect fees
            delta       = _pack(0, 0);
            feesAccrued = _pack(FEE_AMOUNT, FEE_AMOUNT);
        } else if (params.liquidityDelta > 0) {
            // Add liquidity — caller owes pool
            int128 half = int128(params.liquidityDelta / 2);
            delta       = _pack(-half, -half);
            feesAccrued = _pack(0, 0);
        } else {
            // Remove liquidity — pool owes caller
            int128 half = int128((-params.liquidityDelta) / 2);
            delta       = _pack(half, half);
            feesAccrued = _pack(0, 0);
        }
    }

    function take(Currency currency, address to, uint256 amount) external {
        address token = Currency.unwrap(currency);
        if (token != address(0)) IERC20(token).transfer(to, amount);
    }

    function sync(Currency) external {}
    function settle() external pure returns (uint256) { return 0; }

    function _pack(int128 a0, int128 a1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap((int256(a0) << 128) | int256(uint256(uint128(a1))));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mintable ERC-20 for local tokens
// ─────────────────────────────────────────────────────────────────────────────
contract LocalToken {
    string  public name;
    string  public symbol;
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _n, string memory _s) { name = _n; symbol = _s; }

    function mint(address to, uint256 amt) external {
        totalSupply += amt; balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; emit Approval(msg.sender, sp, amt); return true;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "balance");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt); return true;
    }
    function transferFrom(address fr, address to, uint256 amt) external returns (bool) {
        require(allowance[fr][msg.sender] >= amt, "allowance");
        require(balanceOf[fr] >= amt, "balance");
        allowance[fr][msg.sender] -= amt;
        balanceOf[fr] -= amt; balanceOf[to] += amt;
        emit Transfer(fr, to, amt); return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// AnvilSetup — full local deployment for UI / keeper-bot testing
// ─────────────────────────────────────────────────────────────────────────────
contract AnvilSetup is Script {

    MockPoolManager          public mockPM;
    LocalToken               public token0;
    LocalToken               public token1;
    XenorizeInsuranceFund   public insuranceFund;
    XenorizeChainlinkOracle public oracle;
    XenorizeDynamicFeeHook  public feeHook;
    XenorizeAutoCompounder  public autoCompounder;

    address[] internal ANVIL_ACCOUNTS = [
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
        0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
        0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
        0x90F79bf6EB2c4f870365E785982E1f101E93b906,
        0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
    ];

    uint256 constant MINT_AMOUNT = 100_000e18; // 100k tokens per account
    uint256 constant PM_RESERVE  = 500_000e18; // pre-fund PM for simulated fee pay-outs

    function run() public {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("=================================================");
        console2.log("   XENORIZE AMM -- ANVIL LOCAL SETUP");
        console2.log("=================================================");
        console2.log("Chain ID  :", block.chainid);
        console2.log("Deployer  :", deployer);
        console2.log("-------------------------------------------------");

        vm.startBroadcast(deployerKey);

        // 1. Mock PoolManager
        mockPM = new MockPoolManager();
        console2.log("MockPoolManager  :", address(mockPM));

        // 2. Tokens
        token0 = new LocalToken("USDC", "USDC");
        token1 = new LocalToken("WETH", "WETH");
        console2.log("Token0 (USDC)    :", address(token0));
        console2.log("Token1 (WETH)    :", address(token1));

        // Mint to all Anvil test accounts
        for (uint256 i; i < ANVIL_ACCOUNTS.length; i++) {
            token0.mint(ANVIL_ACCOUNTS[i], MINT_AMOUNT);
            token1.mint(ANVIL_ACCOUNTS[i], MINT_AMOUNT);
        }
        // Pre-fund MockPoolManager so take() can return tokens for remove + fees
        token0.mint(address(mockPM), PM_RESERVE);
        token1.mint(address(mockPM), PM_RESERVE);

        // 3. InsuranceFund (ERC-4626, primary asset = token0)
        insuranceFund = new XenorizeInsuranceFund(
            address(token0), deployer, "Xenorize Insurance", "xINS"
        );
        console2.log("InsuranceFund    :", address(insuranceFund));

        // 4. Oracle (no gas feed for local)
        oracle = new XenorizeChainlinkOracle(
            IPoolManager(address(mockPM)), deployer, address(0)
        );
        console2.log("Oracle           :", address(oracle));

        // 5. DynamicFeeHook
        feeHook = new XenorizeDynamicFeeHook(
            IPoolManager(address(mockPM)),
            deployer, deployer,
            address(insuranceFund), address(oracle), address(0)
        );
        console2.log("DynamicFeeHook   :", address(feeHook));

        // 6. AutoCompounder
        autoCompounder = new XenorizeAutoCompounder(
            deployer,
            IPoolManager(address(mockPM)),
            address(insuranceFund),
            address(token0),
            address(token1),
            address(oracle)
        );
        console2.log("AutoCompounder   :", address(autoCompounder));

        // 7. Wire authorizations
        insuranceFund.setAuthorizedDepositor(address(autoCompounder), true);
        insuranceFund.setAuthorizedDepositor(address(feeHook),        true);

        vm.stopBroadcast();

        // 8. Print summary — paste into contracts.js
        console2.log("=================================================");
        console2.log("  PASTE INTO frontend-react/src/lib/contracts.js");
        console2.log("=================================================");
        console2.log("autoCompounder:", address(autoCompounder));
        console2.log("insuranceFund :", address(insuranceFund));
        console2.log("dynamicFeeHook:", address(feeHook));
        console2.log("oracle        :", address(oracle));
        console2.log("token0        :", address(token0));
        console2.log("token1        :", address(token1));
        console2.log("poolManager   :", address(mockPM));
        console2.log("=================================================");
    }
}
