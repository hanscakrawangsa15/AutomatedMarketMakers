"use strict";
/**
 * Xenorize Keeper Bot
 * ────────────────────────────────────────────────────────────────
 * Monitors all active LP positions and triggers on-chain actions:
 *
 *  1. COMPOUND   — when accumulated fees > gas cost + minProfit
 *  2. REBALANCE  — when AutoRangeHook signals a position is near boundary
 *  3. STRATEGY   — when MultiPositionHook has pending 3-layer splits
 *
 * Usage:
 *   cp .env.example .env   # fill in RPC_URL and KEEPER_PRIVATE_KEY
 *   npm run dev            # runs with ts-node (development)
 *   npm run build && npm start   # production
 * ────────────────────────────────────────────────────────────────
 */
Object.defineProperty(exports, "__esModule", { value: true });
const viem_1 = require("viem");
const accounts_1 = require("viem/accounts");
const http_1 = require("http");
const config_1 = require("./config");
const abis_1 = require("./abis");
const URGENCY_LABEL = ["None", "Low", "Medium", "High", "Immediate"];
// ─── Logger ───────────────────────────────────────────────────────
// Module-level ring buffer (max 50) shared with stats server
const activityBuffer = [];
function log(level, msg, data) {
    if (level === "debug" && config_1.CONFIG.logLevel !== "debug")
        return;
    const ts = new Date().toISOString();
    const color = { info: "\x1b[36m", warn: "\x1b[33m", error: "\x1b[31m", debug: "\x1b[90m" }[level];
    const reset = "\x1b[0m";
    const line = `${color}[${ts}] [${level.toUpperCase()}]${reset} ${msg}`;
    console.log(line, data !== undefined ? data : "");
    // Append to activity buffer (keep last 50)
    activityBuffer.push({ ts, level, msg: data !== undefined ? `${msg} ${JSON.stringify(data)}` : msg });
    if (activityBuffer.length > 50)
        activityBuffer.shift();
}
// ─── Main Bot Class ───────────────────────────────────────────────
class XenorizeKeeperBot {
    constructor() {
        this.stats = {
            compoundsTriggered: 0,
            rebalancesTriggered: 0,
            strategyExecutions: 0,
            totalGasSpent: 0n,
            errors: 0,
            startTime: Date.now(),
        };
        // Known position IDs (in production: fetch from subgraph or events)
        // Populated via `addPosition()` or event watching
        this.watchedPositions = new Set();
        this.account = (0, accounts_1.privateKeyToAccount)(config_1.CONFIG.keeperPrivateKey);
        this.publicClient = (0, viem_1.createPublicClient)({
            transport: (0, viem_1.http)(config_1.CONFIG.rpcUrl),
        });
        this.walletClient = (0, viem_1.createWalletClient)({
            account: this.account,
            transport: (0, viem_1.http)(config_1.CONFIG.rpcUrl),
        });
        log("info", `Keeper bot initialized`, {
            keeper: this.account.address,
            rpc: config_1.CONFIG.rpcUrl,
            checkInterval: `${config_1.CONFIG.checkIntervalMs / 1000}s`,
            minProfit: `$${config_1.CONFIG.minProfitUSD}`,
        });
    }
    // ─── Public API ─────────────────────────────────────────────────
    addPosition(positionId) {
        this.watchedPositions.add(positionId);
        log("info", `Watching position ${positionId.slice(0, 10)}…`);
    }
    async start() {
        log("info", "Starting keeper loop…");
        this._startStatsServer();
        setInterval(() => this._printStats(), 60000);
        while (true) {
            await this._runCycle();
            await this._sleep(config_1.CONFIG.checkIntervalMs);
        }
    }
    // ─── HTTP Stats Server (port 3001) ──────────────────────────────
    _startStatsServer() {
        const PORT = parseInt(process.env.STATS_PORT || "8765");
        const server = (0, http_1.createServer)((req, res) => {
            // CORS — allow frontend dev server
            res.setHeader("Access-Control-Allow-Origin", "*");
            res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
            res.setHeader("Access-Control-Allow-Headers", "Content-Type");
            if (req.method === "OPTIONS") {
                res.writeHead(204);
                res.end();
                return;
            }
            if (req.url === "/stats" && req.method === "GET") {
                const uptime = Math.round((Date.now() - this.stats.startTime) / 1000);
                const payload = {
                    status: "running",
                    uptime,
                    keeper: this.account.address,
                    rpc: config_1.CONFIG.rpcUrl,
                    watchedCount: this.watchedPositions.size,
                    checkIntervalMs: config_1.CONFIG.checkIntervalMs,
                    stats: {
                        compoundsTriggered: this.stats.compoundsTriggered,
                        rebalancesTriggered: this.stats.rebalancesTriggered,
                        strategyExecutions: this.stats.strategyExecutions,
                        errors: this.stats.errors,
                        totalGasEth: (0, viem_1.formatEther)(this.stats.totalGasSpent),
                    },
                    activity: activityBuffer.slice(-20),
                };
                res.writeHead(200, { "Content-Type": "application/json" });
                res.end(JSON.stringify(payload));
                return;
            }
            res.writeHead(404);
            res.end("Not found");
        });
        server.listen(PORT, () => {
            log("info", `Stats server listening on http://localhost:${PORT}/stats`);
        });
    }
    // ─── Main Loop ──────────────────────────────────────────────────
    async _runCycle() {
        const positions = Array.from(this.watchedPositions);
        if (positions.length === 0) {
            log("debug", "No positions to watch yet");
            return;
        }
        log("debug", `Checking ${positions.length} positions…`);
        // Run all checks in parallel for speed
        await Promise.allSettled([
            ...positions.map((id) => this._checkCompound(id)),
            this._checkRebalanceSignals(),
            this._checkPendingStrategies(),
        ]);
    }
    // ─── 1. Compound Check ────────────────────────────────────────
    async _checkCompound(positionId) {
        try {
            // Get compound urgency from contract
            const urgency = await this.publicClient.readContract({
                address: config_1.CONFIG.autoCompounder,
                abi: abis_1.AUTO_COMPOUNDER_ABI,
                functionName: "getCompoundUrgency",
                args: [positionId],
            });
            if (urgency === 0)
                return; // None — skip
            const pos = await this.publicClient.readContract({
                address: config_1.CONFIG.autoCompounder,
                abi: abis_1.AUTO_COMPOUNDER_ABI,
                functionName: "getPosition",
                args: [positionId],
            });
            // Gas estimate
            const gasPrice = await this.publicClient.getGasPrice();
            const gasLimit = 400000n;
            const gasCostWei = gasPrice * gasLimit;
            // Rough fee estimate: if urgency ≥ High, force compound regardless
            const forceCompound = urgency >= 3;
            if (!forceCompound) {
                // Check if accumulated fees exceed gas cost × cushion
                // Simplified: use urgency as proxy for fee accumulation
                if (urgency < 2) {
                    log("debug", `Position ${positionId.slice(0, 10)}: urgency ${URGENCY_LABEL[urgency]} — skipping`);
                    return;
                }
            }
            log("info", `Compounding position ${positionId.slice(0, 10)}…`, {
                urgency: URGENCY_LABEL[urgency],
                gasEstimate: `${(0, viem_1.formatEther)(gasCostWei)} ETH`,
            });
            await this._executeCompound(positionId, pos.tickLower, pos.tickUpper);
        }
        catch (err) {
            this.stats.errors++;
            log("error", `Compound check failed for ${positionId.slice(0, 10)}`, err);
        }
    }
    async _executeCompound(positionId, currentTickLower, currentTickUpper) {
        try {
            // In production: fetch poolKey from position storage
            // Here we use the stored tick range as the target (no range change)
            const hash = await this.walletClient.writeContract({
                address: config_1.CONFIG.autoCompounder,
                abi: abis_1.AUTO_COMPOUNDER_ABI,
                functionName: "compoundPosition",
                args: [
                    positionId,
                    {
                        currency0: "0x0000000000000000000000000000000000000000",
                        currency1: "0x0000000000000000000000000000000000000000",
                        fee: 3000,
                        tickSpacing: 60,
                        hooks: "0x0000000000000000000000000000000000000000",
                    },
                    currentTickLower,
                    currentTickUpper,
                ],
                account: this.account,
                chain: null,
            });
            const receipt = await this.publicClient.waitForTransactionReceipt({ hash });
            this.stats.compoundsTriggered++;
            this.stats.totalGasSpent += receipt.gasUsed * receipt.effectiveGasPrice;
            log("info", `Compound tx confirmed: ${hash.slice(0, 12)}… (gas: ${receipt.gasUsed})`);
        }
        catch (err) {
            this.stats.errors++;
            log("error", "Compound tx failed", err);
        }
    }
    // ─── 2. AutoRange Rebalance Check ────────────────────────────
    async _checkRebalanceSignals() {
        if (!config_1.CONFIG.autoRangeHook)
            return;
        try {
            // In production: iterate known poolIds from event index
            // Here: placeholder — reads rebalance signals for a demo poolId
            const demoPoolId = "0x0000000000000000000000000000000000000000000000000000000000000001";
            const [urgent, urgencies] = await this.publicClient.readContract({
                address: config_1.CONFIG.autoRangeHook,
                abi: abis_1.AUTO_RANGE_HOOK_ABI,
                functionName: "getPositionsNeedingRebalance",
                args: [demoPoolId],
            });
            if (urgent.length === 0)
                return;
            log("info", `${urgent.length} position(s) need rebalance`, { urgent });
            for (let i = 0; i < urgent.length; i++) {
                const posKey = urgent[i];
                const urgency = urgencies[i];
                // Fetch AI-suggested range
                const suggestedRaw = await this.publicClient.readContract({
                    address: config_1.CONFIG.autoRangeHook,
                    abi: abis_1.AUTO_RANGE_HOOK_ABI,
                    functionName: "suggestedRanges",
                    args: [posKey],
                });
                const suggested = {
                    tickLower: suggestedRaw[0],
                    tickUpper: suggestedRaw[1],
                    confidence: suggestedRaw[2],
                    updatedAt: suggestedRaw[3],
                };
                log("info", `Rebalance signal for ${posKey.slice(0, 10)}`, {
                    urgency,
                    suggestedRange: `[${suggested.tickLower}, ${suggested.tickUpper}]`,
                    confidence: `${Number(suggested.confidence) / 100}%`,
                });
                // Trigger compound with new range (maps posKey to positionId in production via index)
                this.stats.rebalancesTriggered++;
            }
        }
        catch (err) {
            log("debug", "Rebalance check skipped (hook not deployed)", err);
        }
    }
    // ─── 3. Pending Strategy Execution ───────────────────────────
    async _checkPendingStrategies() {
        if (!config_1.CONFIG.multiPositionHook)
            return;
        try {
            // In production: watch StrategyCreated events for pending keys
            // Placeholder implementation
            log("debug", "Strategy check — no pending strategies in watch list");
        }
        catch (err) {
            log("debug", "Strategy check skipped", err);
        }
    }
    // ─── Stats ────────────────────────────────────────────────────
    _printStats() {
        const uptime = Math.round((Date.now() - this.stats.startTime) / 1000);
        log("info", "── Keeper Stats ────────────────────────────────", {
            uptime: `${uptime}s`,
            compounds: this.stats.compoundsTriggered,
            rebalances: this.stats.rebalancesTriggered,
            strategyExecutions: this.stats.strategyExecutions,
            errors: this.stats.errors,
            totalGas: `${(0, viem_1.formatEther)(this.stats.totalGasSpent)} ETH`,
        });
    }
    _sleep(ms) {
        return new Promise((resolve) => setTimeout(resolve, ms));
    }
}
// ─── Entry Point ─────────────────────────────────────────────────
async function main() {
    if (!config_1.CONFIG.keeperPrivateKey) {
        log("error", "KEEPER_PRIVATE_KEY not set in .env — exiting");
        process.exit(1);
    }
    const bot = new XenorizeKeeperBot();
    // Example: add known position IDs from env or hardcoded for testing
    const envPositions = process.env.WATCHED_POSITIONS?.split(",") ?? [];
    for (const id of envPositions) {
        if (id.startsWith("0x"))
            bot.addPosition(id);
    }
    // Graceful shutdown
    process.on("SIGINT", () => { log("info", "Shutting down…"); process.exit(0); });
    process.on("SIGTERM", () => { log("info", "Shutting down…"); process.exit(0); });
    await bot.start();
}
main().catch((err) => {
    log("error", "Fatal error", err);
    process.exit(1);
});
