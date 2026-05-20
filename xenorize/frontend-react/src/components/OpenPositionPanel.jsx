import React, { useState, useCallback, useEffect, useRef } from "react";
import { Contract, parseUnits, MaxUint256, isAddress } from "ethers";
import { ADDRESSES, AUTO_COMPOUNDER_ABI } from "../lib/contracts.js";
import { priceRangeToTicks, TICK_SPACINGS } from "../lib/tickMath.js";
import RangeChart from "./RangeChart.jsx";

// ── ABIs ────────────────────────────────────────────────────────────────────
const ERC20_ABI = [
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address owner) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

// ── Fee tier catalogue ───────────────────────────────────────────────────────
const FEE_TIERS = [
  { label: "0.01%",  fee: 100,   tickSpacing: 1   },
  { label: "0.05%",  fee: 500,   tickSpacing: 10  },
  { label: "0.1%",   fee: 1000,  tickSpacing: 20  },
  { label: "0.3%",   fee: 3000,  tickSpacing: 60  },
  { label: "1%",     fee: 10000, tickSpacing: 200 },
];

// ── Risk profile config ──────────────────────────────────────────────────────
const RISK_PROFILES   = ["Conservative", "Balanced", "Aggressive"];
const RISK_COLORS     = ["#10b981", "#6366f1", "#ef4444"];
const RISK_WIDTHS     = { 0: 0.25, 1: 0.10, 2: 0.03 };
const RISK_CONFIDENCE = { 0: 82, 1: 91, 2: 74 };

const ZERO_HOOKS = "0x0000000000000000000000000000000000000000";

const DEFAULT_CONFIG = {
  minProfitUSD:       parseUnits("1", 18).toString(),
  gasCushionBps:      "200",
  slippageBps:        "50",
  maxCompoundsPerDay: "24",
  aiRangeEnabled:     true,
  autoRebalance:      true,
};

// ── Built-in pools (addresses from ADDRESSES, labels filled dynamically) ─────
function builtinPools() {
  const t0 = ADDRESSES.token0 || ZERO_HOOKS;
  const t1 = ADDRESSES.token1 || ZERO_HOOKS;
  return [
    { id: "builtin-0", currency0: t0, currency1: t1, fee: 500,  tickSpacing: 10, hooks: ZERO_HOOKS, midPrice: 1, sym0: null, sym1: null },
    { id: "builtin-1", currency0: t0, currency1: t1, fee: 3000, tickSpacing: 60, hooks: ZERO_HOOKS, midPrice: 1, sym0: null, sym1: null },
  ];
}

const LS_KEY = "xenorize_custom_pools_v1";

function loadCustomPools() {
  try { return JSON.parse(localStorage.getItem(LS_KEY) || "[]"); } catch { return []; }
}
function saveCustomPools(pools) {
  localStorage.setItem(LS_KEY, JSON.stringify(pools));
}

function feeLabel(fee) {
  const t = FEE_TIERS.find(f => f.fee === fee);
  return t ? t.label : `${(fee / 10000).toFixed(2)}%`;
}

function poolLabel(p) {
  const s0 = p.sym0 || shortAddr(p.currency0);
  const s1 = p.sym1 || shortAddr(p.currency1);
  const hooks = p.hooks && p.hooks !== ZERO_HOOKS ? ` · Hook` : "";
  return `${s0} / ${s1} (${feeLabel(p.fee)})${hooks}`;
}

function shortAddr(addr) {
  if (!addr || addr === ZERO_HOOKS) return "?";
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

// ── Main component ───────────────────────────────────────────────────────────
export default function OpenPositionPanel({ provider, account }) {
  const [mode,       setMode]      = useState("manual");
  const [pools,      setPools]     = useState(() => [...builtinPools(), ...loadCustomPools()]);
  const [poolIdx,    setPoolIdx]   = useState(0);
  const [risk,       setRisk]      = useState(1);
  const [priceLower, setPriceLow]  = useState("");
  const [priceUpper, setPriceUp]   = useState("");
  const [amount0,    setAmount0]   = useState("");
  const [amount1,    setAmount1]   = useState("");
  const [busy,       setBusy]      = useState(false);
  const [step,       setStep]      = useState("");
  const [txHash,     setTxHash]    = useState(null);
  const [error,      setError]     = useState(null);
  const [aiRange,    setAiRange]   = useState(null);

  // Add-pool form state
  const [showAdd,   setShowAdd]   = useState(false);
  const [newT0,     setNewT0]     = useState("");
  const [newT1,     setNewT1]     = useState("");
  const [newFeeIdx, setNewFeeIdx] = useState(1);     // default 0.05%
  const [newHooks,  setNewHooks]  = useState("");
  const [newSym0,   setNewSym0]   = useState(null);
  const [newSym1,   setNewSym1]   = useState(null);
  const [addErr,    setAddErr]    = useState("");

  // Balances for selected pool's tokens
  const [bal0, setBal0] = useState(null);
  const [bal1, setBal1] = useState(null);

  const pool = pools[poolIdx] ?? pools[0];

  // ── Fetch token symbols for all pools (including builtins) ──────────────
  useEffect(() => {
    if (!provider) return;
    let cancelled = false;
    (async () => {
      const signer = await provider.getSigner();
      const updated = await Promise.all(
        pools.map(async (p) => {
          try {
            const [c0, c1] = await Promise.all([
              new Contract(p.currency0, ERC20_ABI, signer).symbol(),
              new Contract(p.currency1, ERC20_ABI, signer).symbol(),
            ]);
            return { ...p, sym0: c0, sym1: c1 };
          } catch { return p; }
        })
      );
      if (!cancelled) setPools(updated);
    })();
    return () => { cancelled = true; };
  }, [provider, pools.length]);

  // ── Fetch balances when pool or account changes ──────────────────────────
  useEffect(() => {
    if (!provider || !account) return;
    let cancelled = false;
    (async () => {
      try {
        const signer = await provider.getSigner();
        const [b0, b1] = await Promise.all([
          new Contract(pool.currency0, ERC20_ABI, signer).balanceOf(account),
          new Contract(pool.currency1, ERC20_ABI, signer).balanceOf(account),
        ]);
        if (!cancelled) {
          setBal0(b0);
          setBal1(b1);
        }
      } catch { setBal0(null); setBal1(null); }
    })();
    return () => { cancelled = true; };
  }, [provider, account, poolIdx, pools]);

  // ── Auto-set range when risk or pool changes ─────────────────────────────
  useEffect(() => {
    const mid = pool?.midPrice || 1;
    const w   = RISK_WIDTHS[risk] ?? 0.10;
    const r   = {
      priceLower:  mid * (1 - w),
      priceUpper:  mid * (1 + w),
      confidence:  RISK_CONFIDENCE[risk] ?? 88,
    };
    setAiRange(r);
    setPriceLow(r.priceLower.toFixed(6));
    setPriceUp(r.priceUpper.toFixed(6));
  }, [risk, poolIdx]);

  // ── AI mode: lock inputs to AI range ────────────────────────────────────
  useEffect(() => {
    if (mode === "ai" && aiRange) {
      setPriceLow(aiRange.priceLower.toFixed(6));
      setPriceUp(aiRange.priceUpper.toFixed(6));
    }
  }, [mode, aiRange]);

  // ── Tick preview ─────────────────────────────────────────────────────────
  let tickPreview = null;
  try {
    if (priceLower && priceUpper) {
      tickPreview = priceRangeToTicks(parseFloat(priceLower), parseFloat(priceUpper), pool.tickSpacing);
    }
  } catch (_) {}

  // ── Custom pool: preview token symbols as user types address ─────────────
  const symFetchTimer = useRef(null);
  const fetchSym = useCallback(async (addr, setSym) => {
    clearTimeout(symFetchTimer.current);
    setSym(null);
    if (!isAddress(addr) || !provider) return;
    symFetchTimer.current = setTimeout(async () => {
      try {
        const s = await provider.getSigner();
        const sym = await new Contract(addr, ERC20_ABI, s).symbol();
        setSym(sym);
      } catch { setSym("?"); }
    }, 400);
  }, [provider]);

  // ── Add custom pool ──────────────────────────────────────────────────────
  const handleAddPool = useCallback(() => {
    setAddErr("");
    const tier = FEE_TIERS[newFeeIdx];
    if (!isAddress(newT0)) { setAddErr("Invalid Token0 address"); return; }
    if (!isAddress(newT1)) { setAddErr("Invalid Token1 address"); return; }
    if (newT0.toLowerCase() === newT1.toLowerCase()) { setAddErr("Token0 and Token1 must differ"); return; }
    const hooksAddr = isAddress(newHooks) ? newHooks : ZERO_HOOKS;

    const newPool = {
      id:          `custom-${Date.now()}`,
      currency0:   newT0,
      currency1:   newT1,
      fee:         tier.fee,
      tickSpacing: tier.tickSpacing,
      hooks:       hooksAddr,
      midPrice:    1,
      sym0:        newSym0,
      sym1:        newSym1,
    };
    const updated = [...pools, newPool];
    setPools(updated);
    // Persist only custom pools
    saveCustomPools(updated.filter(p => p.id.startsWith("custom-")));
    setPoolIdx(updated.length - 1);
    setShowAdd(false);
    setNewT0(""); setNewT1(""); setNewHooks(""); setNewSym0(null); setNewSym1(null);
  }, [newT0, newT1, newFeeIdx, newHooks, newSym0, newSym1, pools]);

  // ── Remove custom pool ───────────────────────────────────────────────────
  const handleRemovePool = useCallback((idx) => {
    if (!pools[idx].id.startsWith("custom-")) return;
    const updated = pools.filter((_, i) => i !== idx);
    setPools(updated);
    saveCustomPools(updated.filter(p => p.id.startsWith("custom-")));
    setPoolIdx(Math.min(idx, updated.length - 1));
  }, [pools]);

  // ── Open position ────────────────────────────────────────────────────────
  const handleOpen = useCallback(async () => {
    if (!provider || !account) { setError("Connect wallet first"); return; }
    setError(null); setBusy(true); setStep(""); setTxHash(null);
    try {
      const signer     = await provider.getSigner();
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);
      const amt0 = parseUnits(amount0 || "0", 18);
      const amt1 = parseUnits(amount1 || "0", 18);

      // Approvals
      for (const { addr, amt, sym } of [
        { addr: pool.currency0, amt: amt0, sym: pool.sym0 || "Token0" },
        { addr: pool.currency1, amt: amt1, sym: pool.sym1 || "Token1" },
      ]) {
        if (!addr || addr === ZERO_HOOKS) continue;
        const tok     = new Contract(addr, ERC20_ABI, signer);
        const allowed = await tok.allowance(account, ADDRESSES.autoCompounder);
        if (allowed < amt) {
          setStep(`Approving ${sym}…`);
          await (await tok.approve(ADDRESSES.autoCompounder, MaxUint256)).wait();
        }
      }

      setStep("Opening position…");
      const poolKey = {
        currency0:   pool.currency0,
        currency1:   pool.currency1,
        fee:         pool.fee,
        tickSpacing: pool.tickSpacing,
        hooks:       pool.hooks,
      };
      const config = {
        ...DEFAULT_CONFIG,
        aiRangeEnabled: mode === "ai",
        autoRebalance:  mode === "ai",
      };

      let tx;
      if (mode === "manual") {
        if (!tickPreview) throw new Error("Set a valid price range first");
        tx = await compounder.openPosition(
          poolKey, tickPreview.tickLower, tickPreview.tickUpper,
          amt0, amt1, risk, config
        );
      } else {
        tx = await compounder.openPositionAI(poolKey, amt0, amt1, risk, config);
      }

      setStep("Waiting for confirmation…");
      const receipt = await tx.wait();
      setTxHash(receipt.hash);
      setStep("");
      setAmount0(""); setAmount1("");
    } catch (e) {
      setError(e.reason ?? e.shortMessage ?? e.message);
      setStep("");
    } finally { setBusy(false); }
  }, [provider, account, mode, pool, amount0, amount1, risk, tickPreview]);

  // ── Format balance ────────────────────────────────────────────────────────
  const fmtBal = (bn) => {
    if (bn == null) return "—";
    const n = Number(bn) / 1e18;
    return n > 1e6 ? (n / 1e6).toFixed(2) + "M" : n.toLocaleString(undefined, { maximumFractionDigits: 2 });
  };

  // ── JSX ───────────────────────────────────────────────────────────────────
  return (
    <section className="panel open-pos-panel">
      <h2 className="panel-title">
        <span className="panel-icon">➕</span> Open LP Position
      </h2>

      {/* Mode toggle */}
      <div className="mode-toggle">
        <button className={`mode-btn ${mode === "manual" ? "active" : ""}`} onClick={() => setMode("manual")}>
          ✋ Manual Range
        </button>
        <button className={`mode-btn ai ${mode === "ai" ? "active" : ""}`} onClick={() => setMode("ai")}>
          🤖 AI-Managed
        </button>
      </div>
      <p className={`mode-desc ${mode === "ai" ? "ai-desc" : ""}`}>
        {mode === "manual"
          ? "You set the price range. The AI only compounds fees — it will NOT move your range."
          : "AI picks the initial range and automatically rebalances on every compound cycle."}
      </p>

      {/* ── Pool Selector ─────────────────────────────────────────────── */}
      <div className="pool-selector-wrap">
        <label className="form-label" style={{ marginBottom: 6, display: "block" }}>Pool &amp; Pair</label>
        <div className="pool-selector-row">
          <div className="pool-list">
            {pools.map((p, i) => (
              <div
                key={p.id}
                className={`pool-card ${i === poolIdx ? "active" : ""}`}
                onClick={() => setPoolIdx(i)}
              >
                {/* Token pair logos (letter avatars) */}
                <div className="pool-card-logos">
                  <span className="token-avatar">{(p.sym0 || "T")[0]}</span>
                  <span className="token-avatar t1">{(p.sym1 || "T")[0]}</span>
                </div>
                <div className="pool-card-info">
                  <span className="pool-card-pair">
                    {p.sym0 || shortAddr(p.currency0)} / {p.sym1 || shortAddr(p.currency1)}
                  </span>
                  <span className="pool-card-meta">
                    <span className="fee-badge">{feeLabel(p.fee)}</span>
                    {p.hooks !== ZERO_HOOKS && <span className="hook-badge">Hook</span>}
                    {p.id.startsWith("custom-") && <span className="custom-badge">Custom</span>}
                  </span>
                </div>
                {p.id.startsWith("custom-") && (
                  <button
                    className="pool-remove-btn"
                    title="Remove pool"
                    onClick={(e) => { e.stopPropagation(); handleRemovePool(i); }}
                  >×</button>
                )}
              </div>
            ))}

            {/* Add pool card */}
            <div
              className={`pool-card pool-card-add ${showAdd ? "active" : ""}`}
              onClick={() => setShowAdd(v => !v)}
            >
              <span className="pool-add-icon">＋</span>
              <span className="pool-add-label">Add Pool</span>
            </div>
          </div>
        </div>

        {/* Active pool detail pill */}
        {pool && (
          <div className="pool-detail-row">
            <span className="pool-detail-item">
              <span className="pdl">Token0</span>
              <code className="pdv">{pool.sym0 || shortAddr(pool.currency0)}</code>
              <span className="pdaddr">{pool.currency0.slice(0, 10)}…</span>
            </span>
            <span className="pool-detail-sep">⇄</span>
            <span className="pool-detail-item">
              <span className="pdl">Token1</span>
              <code className="pdv">{pool.sym1 || shortAddr(pool.currency1)}</code>
              <span className="pdaddr">{pool.currency1.slice(0, 10)}…</span>
            </span>
            <span className="pool-detail-sep">·</span>
            <span className="pool-detail-item">
              <span className="pdl">Fee</span>
              <code className="pdv">{feeLabel(pool.fee)}</code>
            </span>
            <span className="pool-detail-sep">·</span>
            <span className="pool-detail-item">
              <span className="pdl">Tick</span>
              <code className="pdv">{pool.tickSpacing}</code>
            </span>
            {pool.hooks !== ZERO_HOOKS && (
              <>
                <span className="pool-detail-sep">·</span>
                <span className="pool-detail-item">
                  <span className="pdl">Hook</span>
                  <code className="pdv">{pool.hooks.slice(0, 8)}…</code>
                </span>
              </>
            )}
          </div>
        )}

        {/* ── Add Custom Pool Form ── */}
        {showAdd && (
          <div className="add-pool-form">
            <div className="add-pool-form-title">Configure Custom Pool</div>

            <div className="add-pool-field">
              <label className="form-label">Token 0 Address</label>
              <div className="addr-input-wrap">
                <input
                  className="form-input"
                  placeholder="0x…"
                  value={newT0}
                  onChange={(e) => { setNewT0(e.target.value); fetchSym(e.target.value, setNewSym0); }}
                />
                {newSym0 && <span className={`sym-tag ${newSym0 === "?" ? "err" : ""}`}>{newSym0}</span>}
              </div>
            </div>

            <div className="add-pool-field">
              <label className="form-label">Token 1 Address</label>
              <div className="addr-input-wrap">
                <input
                  className="form-input"
                  placeholder="0x…"
                  value={newT1}
                  onChange={(e) => { setNewT1(e.target.value); fetchSym(e.target.value, setNewSym1); }}
                />
                {newSym1 && <span className={`sym-tag ${newSym1 === "?" ? "err" : ""}`}>{newSym1}</span>}
              </div>
            </div>

            <div className="add-pool-row2">
              <div className="add-pool-field">
                <label className="form-label">Fee Tier</label>
                <div className="fee-tier-picker">
                  {FEE_TIERS.map((t, i) => (
                    <button
                      key={t.fee}
                      className={`fee-tier-btn ${newFeeIdx === i ? "active" : ""}`}
                      onClick={() => setNewFeeIdx(i)}
                    >
                      {t.label}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            <div className="add-pool-field">
              <label className="form-label">Hooks Address <span className="opt-label">(optional)</span></label>
              <input
                className="form-input"
                placeholder={`${ZERO_HOOKS} (no hook)`}
                value={newHooks}
                onChange={(e) => setNewHooks(e.target.value)}
              />
            </div>

            {addErr && <div className="form-error" style={{ margin: "8px 0" }}>⚠️ {addErr}</div>}

            <div className="add-pool-actions">
              <button className="btn btn-primary" onClick={handleAddPool}>
                ＋ Add Pool
              </button>
              <button className="btn" style={{ background: "transparent", border: "1px solid var(--border)" }}
                onClick={() => { setShowAdd(false); setAddErr(""); }}>
                Cancel
              </button>
            </div>
          </div>
        )}
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

      {/* Range Chart */}
      <RangeChart
        midPrice={pool?.midPrice || 1}
        lower={priceLower}
        upper={priceUpper}
        onLower={setPriceLow}
        onUpper={setPriceUp}
        mode={mode}
        aiRange={aiRange}
        tickSpacing={pool?.tickSpacing || 10}
      />

      {/* Price inputs */}
      <div className="price-range-row">
        <div className="form-col">
          <label className="form-label">
            {mode === "ai" ? "AI Lower Price" : "Lower Price"}
            {bal0 != null && (
              <span className="bal-hint">Balance: {fmtBal(bal0)} {pool.sym0 || "T0"}</span>
            )}
          </label>
          <input
            className="form-input"
            type="number"
            value={priceLower}
            placeholder="0.0"
            onChange={(e) => setPriceLow(e.target.value)}
            readOnly={mode === "ai"}
            style={mode === "ai" ? { opacity: 0.6 } : {}}
          />
        </div>
        <span className="range-arrow">→</span>
        <div className="form-col">
          <label className="form-label">
            {mode === "ai" ? "AI Upper Price" : "Upper Price"}
            {bal1 != null && (
              <span className="bal-hint">Balance: {fmtBal(bal1)} {pool.sym1 || "T1"}</span>
            )}
          </label>
          <input
            className="form-input"
            type="number"
            value={priceUpper}
            placeholder="0.0"
            onChange={(e) => setPriceUp(e.target.value)}
            readOnly={mode === "ai"}
            style={mode === "ai" ? { opacity: 0.6 } : {}}
          />
        </div>
      </div>

      {/* Tick preview */}
      {tickPreview && (
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
          Oracle range for {RISK_PROFILES[risk]} ·
          Tick spacing: <strong>{pool?.tickSpacing}</strong>
          {aiRange && <> · Confidence: <strong>{aiRange.confidence}%</strong></>}
        </div>
      )}

      {/* Amounts */}
      <div className="amounts-row">
        <div className="form-col">
          <label className="form-label">
            Amount {pool.sym0 || "Token0"}
            {bal0 != null && (
              <button className="max-btn" onClick={() => setAmount0((Number(bal0) / 1e18).toFixed(4))}>MAX</button>
            )}
          </label>
          <input className="form-input" type="number" placeholder="0.0" value={amount0}
            onChange={(e) => setAmount0(e.target.value)} />
        </div>
        <div className="form-col">
          <label className="form-label">
            Amount {pool.sym1 || "Token1"}
            {bal1 != null && (
              <button className="max-btn" onClick={() => setAmount1((Number(bal1) / 1e18).toFixed(4))}>MAX</button>
            )}
          </label>
          <input className="form-input" type="number" placeholder="0.0" value={amount1}
            onChange={(e) => setAmount1(e.target.value)} />
        </div>
      </div>

      {error  && <div className="form-error">⚠️ {error}</div>}
      {txHash && <div className="form-success">✅ Tx: <code>{txHash.slice(0, 18)}…</code></div>}

      <button
        className={`btn btn-open ${mode === "ai" ? "btn-ai" : "btn-primary"}`}
        onClick={handleOpen}
        disabled={busy || !provider}
        style={!provider ? { opacity: 0.4, cursor: "not-allowed" } : {}}
      >
        {busy
          ? (step || "Processing…")
          : !provider ? "🔌 Connect Wallet to Continue"
          : mode === "ai" ? "🤖 Open AI-Managed Position"
          : "✋ Open Manual Position"}
      </button>

      {!provider && (
        <p className="form-note">Click <strong>Connect Anvil</strong> (top-right) to enable transactions.</p>
      )}
    </section>
  );
}
