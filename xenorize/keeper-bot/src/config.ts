import dotenv from "dotenv";
dotenv.config();

export const CONFIG = {
  // ── RPC ─────────────────────────────────────────────────────────
  rpcUrl:        process.env.RPC_URL     || "http://localhost:8545",
  chainId:       parseInt(process.env.CHAIN_ID || "31337"),

  // ── Keeper wallet ────────────────────────────────────────────────
  keeperPrivateKey: process.env.KEEPER_PRIVATE_KEY || "",

  // ── Contract addresses ───────────────────────────────────────────
  autoCompounder:       (process.env.AUTO_COMPOUNDER_ADDR       || "") as `0x${string}`,
  autoRangeHook:        (process.env.AUTO_RANGE_HOOK_ADDR        || "") as `0x${string}`,
  twammHook:            (process.env.TWAMM_HOOK_ADDR             || "") as `0x${string}`,
  multiPositionHook:    (process.env.MULTI_POSITION_HOOK_ADDR    || "") as `0x${string}`,
  insuranceFund:        (process.env.INSURANCE_FUND_ADDR         || "") as `0x${string}`,
  dynamicFeeHook:       (process.env.DYNAMIC_FEE_HOOK_ADDR       || "") as `0x${string}`,

  // ── Bot parameters ───────────────────────────────────────────────
  checkIntervalMs:   parseInt(process.env.CHECK_INTERVAL_MS  || "15000"),  // 15 sec
  minProfitUSD:      parseFloat(process.env.MIN_PROFIT_USD   || "2.0"),    // $2 min
  gasCushionMultiplier: parseFloat(process.env.GAS_CUSHION   || "2.0"),    // 2× gas

  // ── Logging ──────────────────────────────────────────────────────
  logLevel: process.env.LOG_LEVEL || "info",
} as const;
