import React, { useState, useCallback } from "react";
import { Contract, parseUnits, formatUnits } from "ethers";
import { ADDRESSES, AUTO_COMPOUNDER_ABI } from "../lib/contracts.js";
import { priceRangeToTicks, tickToPrice, formatPrice, TICK_SPACINGS } from "../lib/tickMath.js";

const RISK_PROFILES = ["Conservative", "Balanced", "Aggressive"];
const RISK_COLORS   = ["#10b981", "#6366f1", "#ef4444"];

const DEFAULT_CONFIG = {
  minProfitUSD: parseUnits("1", 18).toString(),
  gasCushionBps: "200",
  slippageBps: "50",
  maxCompoundsPerDay: "24",
  aiRangeEnabled: true,
  autoRebalance: true,
};

// Minimal demo PoolKey — in production this comes from chain/subgraph
const DEMO_POOLS = [
  {
    label: "ETH / USDC (0.05%)",
    currency0: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    currency1: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    fee: 500,
    tickSpacing: 10,
    hooks: "0x0000000000000000000000000000000000000000",
    midPrice: 3200, // approx ETH/USDC
  },
  {
    label: "WBTC / ETH (0.3%)",
    currency0: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
    currency1: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    fee: 3000,
    tickSpacing: 60,
    hooks: "0x0000000000000000000000000000000000000000",
    midPrice: 0.052, // approx WBTC/ETH
  },
];

export default function OpenPositionPanel({ provider, account }) {
  const [mode, setMode]           = useState("manual"); // "manual" | "ai"
  const [poolIdx, setPoolIdx]     = useState(0);
  const [risk, setRisk]           = useState(1);        // Balanced
  const [priceLower, setPriceLow] = useState("");
  const [priceUpper, setPriceUp]  = useState("");
  const [amount0, setAmount0]     = useState("");
  const [amount1, setAmount1]     = useState("");
  const [busy, setBusy]           = useState(false);
  const [txHash, setTxHash]       = useState(null);
  const [error, setError]         = useState(null);

  const pool = DEMO_POOLS[poolIdx];

  // Derived tick preview
  let tickPreview = null;
  try {
    if (mode === "manual" && priceLower && priceUpper) {
      const sp = pool.tickSpacing;
      tickPreview = priceRangeToTicks(parseFloat(priceLower), parseFloat(priceUpper), sp);
    }
  } catch (_) {}

  const handleOpen = useCallback(async () => {
    if (!provider || !account) { setError("Connect wallet first"); return; }
    setError(null);
    setBusy(true);
    setTxHash(null);
    try {
      const signer    = await provider.getSigner();
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);

      const amt0 = parseUnits(amount0 || "0", 18);
      const amt1 = parseUnits(amount1 || "0", 18);

      const poolKey = {
        currency0:   pool.currency0,
        currency1:   pool.currency1,
        fee:         pool.fee,
        tickSpacing: pool.tickSpacing,
        hooks:       pool.hooks,
      };

      const config = {
        minProfitUSD:       DEFAULT_CONFIG.minProfitUSD,
        gasCushionBps:      DEFAULT_CONFIG.gasCushionBps,
        slippageBps:        DEFAULT_CONFIG.slippageBps,
        maxCompoundsPerDay: DEFAULT_CONFIG.maxCompoundsPerDay,
        aiRangeEnabled:     mode === "ai",
        autoRebalance:      mode === "ai",
      };

      let tx;
      if (mode === "manual") {
        if (!tickPreview) throw new Error("Enter valid price range");
        tx = await compounder.openPosition(
          poolKey,
          tickPreview.tickLower,
          tickPreview.tickUpper,
          amt0, amt1, risk, config
        );
      } else {
        tx = await compounder.openPositionAI(poolKey, amt0, amt1, risk, config);
      }

      const receipt = await tx.wait();
      setTxHash(receipt.hash);
      setAmount0(""); setAmount1(""); setPriceLow(""); setPriceUp("");
    } catch (e) {
      setError(e.reason ?? e.message);
    } finally {
      setBusy(false);
    }
  }, [provider, account, mode, pool, amount0, amount1, risk, tickPreview]);

  return (
    <section className="panel open-pos-panel">
      <h2 className="panel-title">
        <span className="panel-icon">➕</span> Open LP Position
      </h2>

      {/* Mode Toggle */}
      <div className="mode-toggle">
        <button
          className={`mode-btn ${mode === "manual" ? "active" : ""}`}
          onClick={() => setMode("manual")}
        >
          ✋ Manual Range
        </button>
        <button
          className={`mode-btn ai ${mode === "ai" ? "active" : ""}`}
          onClick={() => setMode("ai")}
        >
          🤖 AI-Managed
        </button>
      </div>

      {mode === "manual" ? (
        <p className="mode-desc">
          You set the price range. The AI only compounds fees — it will NOT move your range.
        </p>
      ) : (
        <p className="mode-desc ai-desc">
          AI picks the initial range and automatically rebalances on every compound cycle.
          Just deposit and let the oracle optimise for your risk profile.
        </p>
      )}

      {/* Pool Selector */}
      <div className="form-row">
        <label className="form-label">Pool</label>
        <select
          className="form-select"
          value={poolIdx}
          onChange={(e) => setPoolIdx(Number(e.target.value))}
        >
          {DEMO_POOLS.map((p, i) => (
            <option key={i} value={i}>{p.label}</option>
          ))}
        </select>
      </div>

      {/* Risk Profile */}
      <div className="form-row">
        <label className="form-label">Risk Profile</label>
        <div className="risk-picker">
          {RISK_PROFILES.map((r, i) => (
            <button
              key={r}
              className={`risk-btn ${risk === i ? "active" : ""}`}
              style={risk === i ? { borderColor: RISK_COLORS[i], color: RISK_COLORS[i] } : {}}
              onClick={() => setRisk(i)}
            >
              {r}
            </button>
          ))}
        </div>
      </div>

      {/* Price Range (manual only) */}
      {mode === "manual" && (
        <div className="price-range-row">
          <div className="form-col">
            <label className="form-label">Lower Price ({pool.label.split(" ")[2]})</label>
            <input
              className="form-input"
              type="number"
              placeholder={`e.g. ${(pool.midPrice * 0.8).toFixed(4)}`}
              value={priceLower}
              onChange={(e) => setPriceLow(e.target.value)}
            />
          </div>
          <span className="range-arrow">→</span>
          <div className="form-col">
            <label className="form-label">Upper Price</label>
            <input
              className="form-input"
              type="number"
              placeholder={`e.g. ${(pool.midPrice * 1.2).toFixed(4)}`}
              value={priceUpper}
              onChange={(e) => setPriceUp(e.target.value)}
            />
          </div>
        </div>
      )}

      {/* Tick Preview */}
      {mode === "manual" && tickPreview && (
        <div className="tick-preview">
          <span className="tick-label">Tick Lower</span>
          <code className="tick-val">{tickPreview.tickLower}</code>
          <span className="tick-sep">—</span>
          <span className="tick-label">Tick Upper</span>
          <code className="tick-val">{tickPreview.tickUpper}</code>
          <span className="tick-sep">·</span>
          <span className="tick-label">Width</span>
          <code className="tick-val">{tickPreview.tickUpper - tickPreview.tickLower} ticks</code>
        </div>
      )}

      {mode === "ai" && (
        <div className="ai-hint">
          <span className="ai-badge">🤖 AI</span>
          Oracle will compute range from volatility data.
          Risk profile: <strong>{RISK_PROFILES[risk]}</strong> ·
          Tick spacing: <strong>{TICK_SPACINGS[RISK_PROFILES[risk]]}</strong>
        </div>
      )}

      {/* Amounts */}
      <div className="amounts-row">
        <div className="form-col">
          <label className="form-label">Amount token0 (USDC)</label>
          <input
            className="form-input"
            type="number"
            placeholder="0.0"
            value={amount0}
            onChange={(e) => setAmount0(e.target.value)}
          />
        </div>
        <div className="form-col">
          <label className="form-label">Amount token1 (WETH)</label>
          <input
            className="form-input"
            type="number"
            placeholder="0.0"
            value={amount1}
            onChange={(e) => setAmount1(e.target.value)}
          />
        </div>
      </div>

      {/* Error / Success */}
      {error   && <div className="form-error">⚠️ {error}</div>}
      {txHash  && <div className="form-success">✅ Tx: <code>{txHash.slice(0, 18)}…</code></div>}

      {/* Submit */}
      <button
        className={`btn btn-open ${mode === "ai" ? "btn-ai" : "btn-primary"}`}
        onClick={handleOpen}
        disabled={busy || !provider}
      >
        {busy ? "Opening…" : mode === "ai" ? "🤖 Open AI-Managed Position" : "✋ Open Manual Position"}
      </button>

      {!provider && (
        <p className="form-note">Connect wallet to submit on-chain.</p>
      )}
    </section>
  );
}
