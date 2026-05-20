// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2}   from "forge-std/Script.sol";
import {PoolManager}        from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager}       from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks}             from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey}            from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency}           from "@uniswap/v4-core/src/types/Currency.sol";

import {XenorizeInsuranceFund}   from "../src/core/InsuranceFund.sol";
import {XenorizeAutoCompounder}  from "../src/core/AutoCompounder.sol";
import {XenorizeDynamicFeeHook}  from "../src/hooks/DynamicFeeHook.sol";
import {XenorizeChainlinkOracle} from "../src/oracles/XenorizeChainlinkOracle.sol";

/// @notice Simple ERC-20 for local testing
contract TestERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) { name = _name; symbol = _symbol; }
    function mint(address to, uint256 amt) external {
        totalSupply += amt; balanceOf[to] += amt; emit Transfer(address(0), to, amt);
    }
    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt; emit Approval(msg.sender, sp, amt); return true;
    }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt); return true;
    }
    function transferFrom(address fr, address to, uint256 amt) external returns (bool) {
        require(allowance[fr][msg.sender] >= amt, "allowance");
        require(balanceOf[fr] >= amt, "insufficient");
        allowance[fr][msg.sender] -= amt; balanceOf[fr] -= amt; balanceOf[to] += amt;
        emit Transfer(fr, to, amt); return true;
    }
}

/// @title AnvilSetup
/// @notice One-shot local dev setup:
///         1. Deploy v4 PoolManager
///         2. Deploy all Xenorize contracts
///         3. Initialize ETH/USDC pool
///         4. Mint test tokens to all default Anvil accounts
///         5. Approve AutoCompounder to spend tokens
///
/// Usage:
///   forge script script/AnvilSetup.s.sol --tc AnvilSetup \
///     --rpc-url http://127.0.0.1:8545 --broadcast
///
/// Then run: node sync-addresses.js  (to sync addresses to frontend + keeper bot)
contract AnvilSetup is Script {

    // Default Anvil accounts (deterministic from mnemonic "test test test...")
    address[5] internal ANVIL_ACCOUNTS = [
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
        0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
        0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
        0x90F79bf6EB2c4f870365E785982E1f101E93b906,
        0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
    ];

    // sqrtPriceX96 for ETH/USDC ≈ 3200 USDC per ETH
    // price = (sqrtPriceX96 / 2^96)^2 — but tokens are ordered (t0 < t1 by address)
    // We'll use tick 0 (1:1) for simplicity in local dev
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96

    uint256 constant MINT_AMOUNT = 1_000_000 ether; // 1M tokens per account

    function run() public {
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer    = vm.addr(deployerKey);

        console2.log("=================================================");
        console2.log("   XENORIZE -- ANVIL FULL SETUP");
        console2.log("=================================================");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy PoolManager ──────────────────────────────────
        console2.log("\n[1/5] Deploying v4 PoolManager...");
        PoolManager poolManager = new PoolManager(deployer);
        console2.log("  PoolManager     :", address(poolManager));

        // ── 2. Deploy test tokens ─────────────────────────────────
        console2.log("\n[2/5] Deploying test tokens...");
        TestERC20 usdc = new TestERC20("USD Coin",   "USDC");
        TestERC20 weth = new TestERC20("Wrapped ETH","WETH");

        // Ensure token0 < token1 (Uniswap v4 requirement)
        address t0;
        address t1;
        if (address(usdc) < address(weth)) {
            t0 = address(usdc); t1 = address(weth);
            console2.log("  Token0 (USDC)   :", t0);
            console2.log("  Token1 (WETH)   :", t1);
        } else {
            t0 = address(weth); t1 = address(usdc);
            console2.log("  Token0 (WETH)   :", t0);
            console2.log("  Token1 (USDC)   :", t1);
        }

        // ── 3. Deploy Xenorize contracts ──────────────────────────
        console2.log("\n[3/5] Deploying Xenorize contracts...");

        XenorizeInsuranceFund insuranceFund = new XenorizeInsuranceFund(
            t0, deployer, "Xenorize Insurance", "xINS"
        );
        console2.log("  InsuranceFund   :", address(insuranceFund));

        XenorizeChainlinkOracle oracle = new XenorizeChainlinkOracle(
            IPoolManager(address(poolManager)), deployer, address(0)
        );
        console2.log("  Oracle          :", address(oracle));

        XenorizeDynamicFeeHook feeHook = new XenorizeDynamicFeeHook(
            IPoolManager(address(poolManager)),
            deployer, deployer,
            address(insuranceFund), address(oracle), address(0)
        );
        console2.log("  DynamicFeeHook  :", address(feeHook));

        XenorizeAutoCompounder autoCompounder = new XenorizeAutoCompounder(
            deployer,
            IPoolManager(address(poolManager)),
            address(insuranceFund),
            t0, t1,
            address(oracle)
        );
        console2.log("  AutoCompounder  :", address(autoCompounder));

        // Wire authorizations
        insuranceFund.setAuthorizedDepositor(address(autoCompounder), true);
        insuranceFund.setAuthorizedDepositor(address(feeHook),        true);
        console2.log("  Authorizations  : set");

        // ── 4. Initialize pool ────────────────────────────────────
        console2.log("\n[4/5] Initializing ETH/USDC pool...");
        PoolKey memory poolKey = PoolKey({
            currency0:   Currency.wrap(t0),
            currency1:   Currency.wrap(t1),
            fee:         500,           // 0.05%
            tickSpacing: 10,
            hooks:       IHooks(address(0))        // no hook for local init
        });
        poolManager.initialize(poolKey, SQRT_PRICE_1_1);
        console2.log("  Pool initialized at sqrtPrice 1:1");

        // ── 5. Mint tokens to all Anvil accounts ──────────────────
        console2.log("\n[5/5] Minting tokens to Anvil accounts...");
        for (uint i = 0; i < ANVIL_ACCOUNTS.length; i++) {
            TestERC20(t0).mint(ANVIL_ACCOUNTS[i], MINT_AMOUNT);
            TestERC20(t1).mint(ANVIL_ACCOUNTS[i], MINT_AMOUNT);
        }
        TestERC20(t0).mint(deployer, MINT_AMOUNT);
        TestERC20(t1).mint(deployer, MINT_AMOUNT);
        console2.log("  Minted 1M each to 6 accounts");
        console2.log("  (Token approvals handled automatically by the frontend)");

        vm.stopBroadcast();

        console2.log("\n=================================================");
        console2.log("   SETUP COMPLETE");
        console2.log("=================================================");
        console2.log("PoolManager    :", address(poolManager));
        console2.log("Token0         :", t0);
        console2.log("Token1         :", t1);
        console2.log("InsuranceFund  :", address(insuranceFund));
        console2.log("Oracle         :", address(oracle));
        console2.log("DynamicFeeHook :", address(feeHook));
        console2.log("AutoCompounder :", address(autoCompounder));
        console2.log("=================================================");
        console2.log("Next: node sync-addresses.js");
        console2.log("=================================================");
    }
}

