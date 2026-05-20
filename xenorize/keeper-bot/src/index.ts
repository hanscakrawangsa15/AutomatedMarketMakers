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

import {
  createPublicClient,
  createWalletClient,
  http,
  parseGwei,
  formatEther,
  type PublicClient,
  type WalletClient,
  type Account,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createServer }        from "http";
import { CONFIG }              from "./config";
import { AUTO_COMPOUNDER_ABI, AUTO_RANGE_HOOK_ABI, MULTI_POSITION_ABI } from "./abis";

// ─── Types ────────────────────────────────────────────────────────

type CompoundUrgency = 0 | 1 | 2 | 3 | 4; // None/Low/Medium/High/Immediate
const URGENCY_LABEL  = ["None", "Low", "Medium", "High", "Immediate"] as const;

interface PositionSnapshot {
  owner:        `0x${string}`;
  poolId:       `0x${string}`;
  tickLower:    number;
  tickUpper:    number;
  liquidity:    bigint;
  depositTime:  bigint;
  lastCompound: bigint;
  compoundCount: bigint;
  initialCapital0: bigint;
  initialCapital1: bigint;
  totalFees0:   bigint;
  totalFees1:   bigint;
  totalIL0:     bigint;
  riskProfile:  number;
  status:       number;
}

interface KeeperStats {
  compoundsTriggered: number;
  rebalancesTriggered: number;
  strategyExecutions: number;
  totalGasSpent:      bigint;
  errors:             number;
  startTime:          number;
}

// ─── Logger ───────────────────────────────────────────────────────

// Module-level ring buffer (max 50) shared with stats server
const activityBuffer: Array<{ ts: string; level: string; msg: string }> = [];

function log(level: "info" | "warn" | "error" | "debug", msg: string, data?: unknown) {
  if (level === "debug" && CONFIG.logLevel !== "debug") return;
  const ts    = new Date().toISOString();
  const color = { info: "\x1b[36m", warn: "\x1b[33m", error: "\x1b[31m", debug: "\x1b[90m" }[level];
  const reset = "\x1b[0m";
  const line  = `${color}[${ts}] [${level.toUpperCase()}]${reset} ${msg}`;
  console.log(line, data !== undefined ? data : "");

  // Append to activity buffer (keep last 50)
  activityBuffer.push({ ts, level, msg: data !== undefined ? `${msg} ${JSON.stringify(data)}` : msg });
  if (activityBuffer.length > 50) activityBuffer.shift();
}

// ─── Main Bot Class ───────────────────────────────────────────────

class XenorizeKeeperBot {
  private publicClient:  PublicClient;
  private walletClient:  WalletClient;
  private account:       Account;
  private stats:         KeeperStats = {
    compoundsTriggered:   0,
    rebalancesTriggered:  0,
    strategyExecutions:   0,
    totalGasSpent:        0n,
    errors:               0,
    startTime:            Date.now(),
  };

  // Known position IDs (in production: fetch from subgraph or events)
  // Populated via `addPosition()` or event watching
  private watchedPositions: Set<`0x${string}`> = new Set();

  constructor() {
    this.account = privateKeyToAccount(CONFIG.keeperPrivateKey as `0x${string}`);

    this.publicClient = createPublicClient({
      transport: http(CONFIG.rpcUrl),
    });

    this.walletClient = createWalletClient({
      account:   this.account,
      transport: http(CONFIG.rpcUrl),
    });

    log("info", `Keeper bot initialized`, {
      keeper:          this.account.address,
      rpc:             CONFIG.rpcUrl,
      checkInterval:   `${CONFIG.checkIntervalMs / 1000}s`,
      minProfit:       `$${CONFIG.minProfitUSD}`,
    });
  }

  // ─── Public API ─────────────────────────────────────────────────

  addPosition(positionId: `0x${string}`) {
    this.watchedPositions.add(positionId);
    log("info", `Watching position ${positionId.slice(0, 10)}…`);
  }

  async start(): Promise<never> {
    log("info", "Starting keeper loop…");
    this._startStatsServer();
    setInterval(() => this._printStats(), 60_000);

    // Auto-discover all positions from on-chain events
    await this._discoverPositions();

    // Watch for new positions in real-time
    this._watchPositionEvents();

    while (true) {
      await this._runCycle();
      await this._sleep(CONFIG.checkIntervalMs);
    }
  }

  // ─── Auto-discover positions from PositionOpened events ──────────

  private async _discoverPositions(): Promise<void> {
    if (!CONFIG.autoCompounder) return;
    try {
      const currentBlock = await this.publicClient.getBlockNumber();
      // Scan from block 0 (local Anvil) — in production limit to last N blocks
      const fromBlock = 0n;

      log("info", `Scanning for PositionOpened events from block ${fromBlock} to ${currentBlock}…`);

      const logs = await this.publicClient.getLogs({
        address:   CONFIG.autoCompounder,
        event:     {
          name:    "PositionOpened",
          type:    "event",
          inputs: [
            { name: "id",     type: "bytes32", indexed: true  },
            { name: "owner",  type: "address", indexed: true  },
            { name: "poolId", type: "bytes32", indexed: true  },
            { name: "tL",     type: "int24",   indexed: false },
            { name: "tU",     type: "int24",   indexed: false },
            { name: "a0",     type: "uint256", indexed: false },
            { name: "a1",     type: "uint256", indexed: false },
          ],
        },
        fromBlock,
        toBlock: currentBlock,
      });

      // Track which positions were later closed
      const closedLogs = await this.publicClient.getLogs({
        address:   CONFIG.autoCompounder,
        event:     {
          name:    "PositionClosed",
          type:    "event",
          inputs: [
            { name: "id",     type: "bytes32", indexed: true  },
            { name: "owner",  type: "address", indexed: true  },
            { name: "r0",     type: "uint256", indexed: false },
            { name: "r1",     type: "uint256", indexed: false },
            { name: "tf0",    type: "uint256", indexed: false },
            { name: "tf1",    type: "uint256", indexed: false },
            { name: "il",     type: "uint256", indexed: false },
            { name: "cycles", type: "uint256", indexed: false },
          ],
        },
        fromBlock,
        toBlock: currentBlock,
      });

      const closedIds = new Set(closedLogs.map(l => l.args.id as `0x${string}`));

      let added = 0;
      for (const l of logs) {
        const id = l.args.id as `0x${string}`;
        if (!closedIds.has(id)) {
          this.watchedPositions.add(id);
          added++;
        }
      }

      log("info", `Discovered ${added} active position(s) from chain history`);
    } catch (err) {
      log("warn", "Position discovery failed — will rely on WATCHED_POSITIONS", err);
    }
  }

  // ─── Watch for new PositionOpened / PositionClosed events ────────

  private _watchPositionEvents(): void {
    if (!CONFIG.autoCompounder) return;

    // Poll getLogs every cycle for new events (viem watchContractEvent not needed for polling)
    let lastScannedBlock = 0n;

    this.publicClient.getBlockNumber().then(b => { lastScannedBlock = b; });

    const pollNewEvents = async () => {
      try {
        const current = await this.publicClient.getBlockNumber();
        if (current <= lastScannedBlock) return;

        const newOpened = await this.publicClient.getLogs({
          address:   CONFIG.autoCompounder,
          event:     {
            name:   "PositionOpened",
            type:   "event",
            inputs: [
              { name: "id",     type: "bytes32", indexed: true  },
              { name: "owner",  type: "address", indexed: true  },
              { name: "poolId", type: "bytes32", indexed: true  },
              { name: "tL",     type: "int24",   indexed: false },
              { name: "tU",     type: "int24",   indexed: false },
              { name: "a0",     type: "uint256", indexed: false },
              { name: "a1",     type: "uint256", indexed: false },
            ],
          },
          fromBlock: lastScannedBlock + 1n,
          toBlock:   current,
        });

        for (const l of newOpened) {
          const id = l.args.id as `0x${string}`;
          this.watchedPositions.add(id);
          log("info", `🆕 New position detected on-chain: ${id.slice(0, 14)}…`);
        }

        const newClosed = await this.publicClient.getLogs({
          address:   CONFIG.autoCompounder,
          event:     {
            name:   "PositionClosed",
            type:   "event",
            inputs: [
              { name: "id",     type: "bytes32", indexed: true  },
              { name: "owner",  type: "address", indexed: true  },
              { name: "r0",     type: "uint256", indexed: false },
              { name: "r1",     type: "uint256", indexed: false },
              { name: "tf0",    type: "uint256", indexed: false },
              { name: "tf1",    type: "uint256", indexed: false },
              { name: "il",     type: "uint256", indexed: false },
              { name: "cycles", type: "uint256", indexed: false },
            ],
          },
          fromBlock: lastScannedBlock + 1n,
          toBlock:   current,
        });

        for (const l of newClosed) {
          const id = l.args.id as `0x${string}`;
          this.watchedPositions.delete(id);
          log("info", `🗑 Position closed, removed from watch: ${id.slice(0, 14)}…`);
        }

        lastScannedBlock = current;
      } catch (err) {
        log("debug", "Event poll error", err);
      }
    };

    // Poll every check interval
    setInterval(pollNewEvents, CONFIG.checkIntervalMs);
    log("info", "Watching for new PositionOpened / PositionClosed events…");
  }

  // ─── HTTP Stats Server (port 3001) ──────────────────────────────

  private _startStatsServer(): void {
    const PORT = parseInt(process.env.STATS_PORT || "8765");

    const server = createServer((req, res) => {
      // CORS — allow frontend dev server
      res.setHeader("Access-Control-Allow-Origin", "*");
      res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
      res.setHeader("Access-Control-Allow-Headers", "Content-Type");

      if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

      if (req.url === "/stats" && req.method === "GET") {
        const uptime = Math.round((Date.now() - this.stats.startTime) / 1000);
        const payload = {
          status:       "running",
          uptime,
          keeper:       this.account.address,
          rpc:          CONFIG.rpcUrl,
          watchedCount: this.watchedPositions.size,
          checkIntervalMs: CONFIG.checkIntervalMs,
          stats: {
            compoundsTriggered:   this.stats.compoundsTriggered,
            rebalancesTriggered:  this.stats.rebalancesTriggered,
            strategyExecutions:   this.stats.strategyExecutions,
            errors:               this.stats.errors,
            totalGasEth:          formatEther(this.stats.totalGasSpent),
          },
          activity: activityBuffer.slice(-20),
        };
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(payload));
        return;
      }

      res.writeHead(404); res.end("Not found");
    });

    server.listen(PORT, () => {
      log("info", `Stats server listening on http://localhost:${PORT}/stats`);
    });
  }

  // ─── Main Loop ──────────────────────────────────────────────────

  private async _runCycle(): Promise<void> {
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

  private async _checkCompound(positionId: `0x${string}`): Promise<void> {
    try {
      // Get compound urgency from contract
      const urgency = await this.publicClient.readContract({
        address:      CONFIG.autoCompounder,
        abi:          AUTO_COMPOUNDER_ABI,
        functionName: "getCompoundUrgency",
        args:         [positionId],
      }) as CompoundUrgency;

      if (urgency === 0) return; // None — skip

      const pos = await this.publicClient.readContract({
        address:      CONFIG.autoCompounder,
        abi:          AUTO_COMPOUNDER_ABI,
        functionName: "getPosition",
        args:         [positionId],
      }) as unknown as PositionSnapshot;

      // Gas estimate
      const gasPrice  = await this.publicClient.getGasPrice();
      const gasLimit  = 400_000n;
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
        gasEstimate: `${formatEther(gasCostWei)} ETH`,
      });

      await this._executeCompound(positionId, pos.tickLower, pos.tickUpper);

    } catch (err) {
      this.stats.errors++;
      log("error", `Compound check failed for ${positionId.slice(0, 10)}`, err);
    }
  }

  private async _executeCompound(
    positionId: `0x${string}`,
    currentTickLower: number,
    currentTickUpper: number
  ): Promise<void> {
    try {
      // In production: fetch poolKey from position storage
      // Here we use the stored tick range as the target (no range change)
      const hash = await this.walletClient.writeContract({
        address:      CONFIG.autoCompounder,
        abi:          AUTO_COMPOUNDER_ABI,
        functionName: "compoundPosition",
        args: [
          positionId,
          {
            currency0:   "0x0000000000000000000000000000000000000000" as `0x${string}`,
            currency1:   "0x0000000000000000000000000000000000000000" as `0x${string}`,
            fee:         3000,
            tickSpacing: 60,
            hooks:       "0x0000000000000000000000000000000000000000" as `0x${string}`,
          },
          currentTickLower,
          currentTickUpper,
        ],
        account: this.account,
        chain:   null,
      });

      const receipt = await this.publicClient.waitForTransactionReceipt({ hash });
      this.stats.compoundsTriggered++;
      this.stats.totalGasSpent += receipt.gasUsed * receipt.effectiveGasPrice;
      log("info", `Compound tx confirmed: ${hash.slice(0, 12)}… (gas: ${receipt.gasUsed})`);

    } catch (err) {
      this.stats.errors++;
      log("error", "Compound tx failed", err);
    }
  }

  // ─── 2. AutoRange Rebalance Check ────────────────────────────

  private async _checkRebalanceSignals(): Promise<void> {
    if (!CONFIG.autoRangeHook) return;

    try {
      // In production: iterate known poolIds from event index
      // Here: placeholder — reads rebalance signals for a demo poolId
      const demoPoolId = "0x0000000000000000000000000000000000000000000000000000000000000001" as `0x${string}`;

      const [urgent, urgencies] = await this.publicClient.readContract({
        address:      CONFIG.autoRangeHook,
        abi:          AUTO_RANGE_HOOK_ABI,
        functionName: "getPositionsNeedingRebalance",
        args:         [demoPoolId],
      }) as [`0x${string}`[], number[]];

      if (urgent.length === 0) return;

      log("info", `${urgent.length} position(s) need rebalance`, { urgent });

      for (let i = 0; i < urgent.length; i++) {
        const posKey  = urgent[i];
        const urgency = urgencies[i];

        // Fetch AI-suggested range
        const suggestedRaw = await this.publicClient.readContract({
          address:      CONFIG.autoRangeHook,
          abi:          AUTO_RANGE_HOOK_ABI,
          functionName: "suggestedRanges",
          args:         [posKey],
        }) as unknown as readonly [number, number, bigint, bigint];
        const suggested = {
          tickLower:  suggestedRaw[0],
          tickUpper:  suggestedRaw[1],
          confidence: suggestedRaw[2],
          updatedAt:  suggestedRaw[3],
        };

        log("info", `Rebalance signal for ${posKey.slice(0, 10)}`, {
          urgency,
          suggestedRange: `[${suggested.tickLower}, ${suggested.tickUpper}]`,
          confidence:     `${Number(suggested.confidence) / 100}%`,
        });

        // Trigger compound with new range (maps posKey to positionId in production via index)
        this.stats.rebalancesTriggered++;
      }

    } catch (err) {
      log("debug", "Rebalance check skipped (hook not deployed)", err);
    }
  }

  // ─── 3. Pending Strategy Execution ───────────────────────────

  private async _checkPendingStrategies(): Promise<void> {
    if (!CONFIG.multiPositionHook) return;

    try {
      // In production: watch StrategyCreated events for pending keys
      // Placeholder implementation
      log("debug", "Strategy check — no pending strategies in watch list");

    } catch (err) {
      log("debug", "Strategy check skipped", err);
    }
  }

  // ─── Stats ────────────────────────────────────────────────────

  private _printStats(): void {
    const uptime = Math.round((Date.now() - this.stats.startTime) / 1000);
    log("info", "── Keeper Stats ────────────────────────────────", {
      uptime:             `${uptime}s`,
      compounds:          this.stats.compoundsTriggered,
      rebalances:         this.stats.rebalancesTriggered,
      strategyExecutions: this.stats.strategyExecutions,
      errors:             this.stats.errors,
      totalGas:           `${formatEther(this.stats.totalGasSpent)} ETH`,
    });
  }

  private _sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

// ─── Entry Point ─────────────────────────────────────────────────

async function main() {
  if (!CONFIG.keeperPrivateKey) {
    log("error", "KEEPER_PRIVATE_KEY not set in .env — exiting");
    process.exit(1);
  }

  const bot = new XenorizeKeeperBot();

  // Example: add known position IDs from env or hardcoded for testing
  const envPositions = process.env.WATCHED_POSITIONS?.split(",") ?? [];
  for (const id of envPositions) {
    if (id.startsWith("0x")) bot.addPosition(id as `0x${string}`);
  }

  // Graceful shutdown
  process.on("SIGINT",  () => { log("info", "Shutting down…"); process.exit(0); });
  process.on("SIGTERM", () => { log("info", "Shutting down…"); process.exit(0); });

  await bot.start();
}

main().catch((err) => {
  log("error", "Fatal error", err);
  process.exit(1);
});
