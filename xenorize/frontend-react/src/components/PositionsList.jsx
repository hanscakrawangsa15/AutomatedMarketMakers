import React, { useState, useEffect, useCallback, useRef } from "react";
import { Contract, formatUnits } from "ethers";
import { ADDRESSES, AUTO_COMPOUNDER_ABI } from "../lib/contracts.js";
import { tickToPrice, priceRangeToTicks, formatPrice } from "../lib/tickMath.js";
import RangeChart from "./RangeChart.jsx";

// ── Constants ────────────────────────────────────────────────────────────────
const STATUS_LABEL = ["Active", "OutOfRange", "Closed"];
const RISK_LABEL   = ["Conservative", "Balanced", "Aggressive"];
const PRICE_TICK   = 3000;
const HISTORY_LEN  = 80;

function fmt18(v) {
  try { return parseFloat(formatUnits(v, 18)).toFixed(4); } catch { return "0"; }
}
function fmtPct(n, decimals = 2) {
  return `${n >= 0 ? "+" : ""}${n.toFixed(decimals)}%`;
}

// ── Pre-seeded random walk to fill initial history ───────────────────────────
function buildInitialHistory(startPrice, len = HISTORY_LEN) {
  let seed = (startPrice * 1000 | 0) || 1;
  let p    = startPrice;
  const out = [];
  for (let i = 0; i < len; i++) {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    const r = seed / 0xffffffff;
    // ±2.2% drift each step — large enough to create visible candle bodies
    p = Math.max(startPrice * 0.4, p + (r - 0.498) * 0.022 * startPrice);
    out.push(p);
  }
  return out;
}

// ── Simulated price hook ─────────────────────────────────────────────────────
function useSimulatedPrice(startPrice, interval = PRICE_TICK) {
  const [history, setHistory] = useState(() => buildInitialHistory(startPrice));
  const [current, setCurrent] = useState(startPrice);
  const seedRef = useRef((startPrice * 1000 | 0) || 1);

  useEffect(() => {
    const init = buildInitialHistory(startPrice);
    setHistory(init);
    setCurrent(init[init.length - 1]);
    seedRef.current = (startPrice * 1000 | 0) || 1;
  }, [startPrice]);

  useEffect(() => {
    const id = setInterval(() => {
      seedRef.current = (seedRef.current * 1664525 + 1013904223) >>> 0;
      const rand = seedRef.current / 0xffffffff;
      const drift = (rand - 0.498) * 0.022 * startPrice;
      setCurrent(prev => {
        const next = Math.max(startPrice * 0.4, prev + drift);
        setHistory(h => [...h.slice(1), next]);
        return next;
      });
    }, interval);
    return () => clearInterval(id);
  }, [startPrice, interval]);

  return { current, history };
}

// ── Position health + realistic IL ──────────────────────────────────────────
// V3 IL formula: when price moves from P0 to P, within range [Pa, Pb]:
//   effective = clamp(P, Pa, Pb)
//   k = effective / P0
//   IL% = (2√k / (1+k) - 1) × 100
function usePositionHealth(priceLo, priceHi) {
  const entryPrice = Math.sqrt(priceLo * priceHi);
  const { current, history } = useSimulatedPrice(entryPrice);
  const prevRef = useRef({ inRange: true, ilPct: 0 });

  // IL calculation
  const effectiveP = Math.max(priceLo, Math.min(priceHi, current));
  const k = effectiveP / entryPrice;
  const ilPct = (2 * Math.sqrt(k) / (1 + k) - 1) * 100; // ≤ 0

  const inRange = current >= priceLo && current <= priceHi;
  const rangeWidth = priceHi - priceLo;
  const nearLower  = inRange && current < priceLo + rangeWidth * 0.12;
  const nearUpper  = inRange && current > priceHi - rangeWidth * 0.12;
  const pctFromEntry = (current - entryPrice) / entryPrice * 100;

  // Simulated fee accumulation (grows faster when in range)
  const [simFees, setSimFees] = useState(0);
  useEffect(() => {
    const id = setInterval(() => {
      setSimFees(f => f + (inRange ? 0.0006 : 0.00002));
    }, PRICE_TICK);
    return () => clearInterval(id);
  }, [inRange]);

  // Compute change events vs previous state
  const [alerts, setAlerts] = useState([]);
  useEffect(() => {
    const prev = prevRef.current;
    const newAlerts = [];

    if (!inRange && prev.inRange) {
      newAlerts.push({ id: Date.now(), type: "out_range", level: "warn",
        msg: "Price exited range — fees paused until price returns" });
    }
    if (inRange && !prev.inRange) {
      newAlerts.push({ id: Date.now(), type: "in_range", level: "ok",
        msg: "Price returned to range — fees resuming" });
    }
    if (ilPct < -3 && prev.ilPct >= -3) {
      newAlerts.push({ id: Date.now(), type: "il_high", level: "warn",
        msg: `IL reached ${Math.abs(ilPct).toFixed(2)}% — consider adjusting range` });
    }
    if (ilPct < -5 && prev.ilPct >= -5) {
      newAlerts.push({ id: Date.now(), type: "il_critical", level: "error",
        msg: `Critical IL: ${Math.abs(ilPct).toFixed(2)}% — range adjustment recommended` });
    }
    if (simFees > 1 && prev.simFees <= 1) {
      newAlerts.push({ id: Date.now(), type: "compound_ready", level: "info",
        msg: "Fees accumulated — compounding now would be profitable" });
    }

    prevRef.current = { inRange, ilPct, simFees };
    if (newAlerts.length > 0) setAlerts(a => [...a.slice(-4), ...newAlerts]);
  }, [inRange, ilPct, simFees]);

  const dismissAlert = useCallback((id) => setAlerts(a => a.filter(x => x.id !== id)), []);

  return {
    current, history, entryPrice,
    inRange, nearLower, nearUpper,
    ilPct, simFees, pctFromEntry,
    alerts, dismissAlert,
  };
}

// ── Alert Banner ─────────────────────────────────────────────────────────────
function AlertBanner({ alerts, onDismiss }) {
  if (!alerts.length) return null;
  const LEVEL_STYLE = {
    error: { bg: "#ef444420", border: "#ef4444", icon: "🔴" },
    warn:  { bg: "#f59e0b18", border: "#f59e0b", icon: "⚠️" },
    ok:    { bg: "#10b98118", border: "#10b981", icon: "✅" },
    info:  { bg: "#6366f118", border: "#6366f1", icon: "ℹ️" },
  };
  return (
    <div className="alert-center">
      {alerts.map(a => {
        const s = LEVEL_STYLE[a.level] ?? LEVEL_STYLE.info;
        return (
          <div key={a.id} className="alert-item"
            style={{ background: s.bg, borderLeft: `3px solid ${s.border}` }}>
            <span className="alert-icon">{s.icon}</span>
            <span className="alert-msg">{a.msg}</span>
            <button className="alert-dismiss" onClick={() => onDismiss(a.id)}>✕</button>
          </div>
        );
      })}
    </div>
  );
}

// PositionMiniChart removed — replaced by RangeChart readOnly={true}

// ── Health Badge ──────────────────────────────────────────────────────────────
function HealthBadges({ inRange, nearLower, nearUpper, ilPct, simFees }) {
  const badges = [];
  if (!inRange)         badges.push({ label: "Out of Range",        color: "#f59e0b", bg: "#f59e0b20" });
  if (nearLower)        badges.push({ label: "Near Lower Boundary", color: "#f59e0b", bg: "#f59e0b15" });
  if (nearUpper)        badges.push({ label: "Near Upper Boundary", color: "#f59e0b", bg: "#f59e0b15" });
  if (ilPct < -5)       badges.push({ label: `IL ${Math.abs(ilPct).toFixed(1)}% CRITICAL`, color: "#ef4444", bg: "#ef444420" });
  else if (ilPct < -2)  badges.push({ label: `IL ${Math.abs(ilPct).toFixed(1)}%`,          color: "#f59e0b", bg: "#f59e0b15" });
  if (simFees > 1)      badges.push({ label: "Compound Ready",      color: "#10b981", bg: "#10b98115" });
  if (!badges.length) return null;
  return (
    <div className="health-badges">
      {badges.map((b, i) => (
        <span key={i} className="health-badge" style={{ color: b.color, background: b.bg, border: `1px solid ${b.color}40` }}>
          {b.label}
        </span>
      ))}
    </div>
  );
}

// ── Loyalty Gauge ─────────────────────────────────────────────────────────────
function LoyaltyGauge({ depositTime }) {
  const ageDays  = Math.max(0, (Date.now() / 1000 - Number(depositTime || 0)) / 86400);
  const scoreBps = Math.min(ageDays / 90, 1) * 10000;
  const pct      = scoreBps / 100;                    // 0–100
  const multi    = (1 + scoreBps / 10000).toFixed(2); // 1.00–2.00x
  const ilCov    = (pct / 2).toFixed(1);              // 0–50 %

  const tier      = scoreBps >= 6667 ? "Gold" : scoreBps >= 3333 ? "Silver" : "Bronze";
  const tierColor = tier === "Gold" ? "#ffd700" : tier === "Silver" ? "#a0a0a0" : "#cd7f32";

  // Semi-circle SVG arc gauge
  // Center (50, 50), radius 40 — viewBox "0 0 100 58" crops bottom half
  const R = 40, CX = 50, CY = 50;
  const startX = CX - R;          // 10
  const endX   = CX + R;          // 90
  const trackD = `M ${startX} ${CY} A ${R} ${R} 0 0 0 ${endX} ${CY}`;

  // Endpoint for progress arc:
  // Going counterclockwise from 180° by pct×180°
  // angle = (180 + pct/100*180)° in SVG convention
  const angleDeg = 180 + (pct / 100) * 180;
  const angleRad = angleDeg * (Math.PI / 180);
  const px = CX + R * Math.cos(angleRad);
  const py = CY + R * Math.sin(angleRad);

  const progressD =
    pct < 0.5  ? "" :
    pct > 99.5 ? trackD :
    `M ${startX} ${CY} A ${R} ${R} 0 0 0 ${px.toFixed(2)} ${py.toFixed(2)}`;

  // Tier boundary markers (at 33.3% and 66.7% along the arc)
  const markerAngle = (frac) => {
    const a = (180 + frac * 180) * (Math.PI / 180);
    return { x: CX + R * Math.cos(a), y: CY + R * Math.sin(a) };
  };
  const m1 = markerAngle(1 / 3);
  const m2 = markerAngle(2 / 3);

  return (
    <div className="loyalty-gauge">
      <svg viewBox="0 0 100 56" className="loyalty-gauge__svg" aria-label={`Loyalty ${tier}`}>
        {/* Track */}
        <path d={trackD} fill="none" stroke="#1e293b" strokeWidth="7" strokeLinecap="round" />
        {/* Progress fill */}
        {progressD && (
          <path d={progressD} fill="none" stroke={tierColor} strokeWidth="7" strokeLinecap="round" />
        )}
        {/* Tier boundary ticks */}
        <circle cx={m1.x.toFixed(2)} cy={m1.y.toFixed(2)} r="2.5" fill="#252538" />
        <circle cx={m2.x.toFixed(2)} cy={m2.y.toFixed(2)} r="2.5" fill="#252538" />
        {/* Score label */}
        <text x={CX} y="44" textAnchor="middle" fill={tierColor} fontSize="13" fontWeight="700">
          {scoreBps >= 9999 ? "MAX" : `${Math.round(pct)}%`}
        </text>
        <text x={CX} y="54" textAnchor="middle" fill="#475569" fontSize="7" letterSpacing="1">
          LOYALTY
        </text>
      </svg>

      <div className="loyalty-gauge__info">
        <div className="loyalty-gauge__tier" style={{ color: tierColor }}>
          {tier === "Gold" ? "🥇" : tier === "Silver" ? "🥈" : "🥉"} {tier}
        </div>
        <div className="loyalty-gauge__rows">
          <div className="loyalty-gauge__row">
            <span className="loyalty-gauge__key">IL Multiplier</span>
            <span className="loyalty-gauge__val" style={{ color: tierColor }}>{multi}x</span>
          </div>
          <div className="loyalty-gauge__row">
            <span className="loyalty-gauge__key">IL Coverage</span>
            <span className="loyalty-gauge__val">~{ilCov}%</span>
          </div>
          <div className="loyalty-gauge__row">
            <span className="loyalty-gauge__key">Age</span>
            <span className="loyalty-gauge__val">{ageDays.toFixed(1)}d / 90d</span>
          </div>
        </div>
        {/* Progress bar with tier zones */}
        <div className="loyalty-gauge__track">
          <div className="loyalty-gauge__fill" style={{ width: `${Math.min(pct, 100)}%`, background: tierColor }} />
          <div className="loyalty-gauge__tick" style={{ left: "33.3%" }} />
          <div className="loyalty-gauge__tick" style={{ left: "66.7%" }} />
        </div>
        <div className="loyalty-gauge__labels">
          <span style={{ color: "#cd7f32" }}>Bronze</span>
          <span style={{ color: "#a0a0a0" }}>Silver</span>
          <span style={{ color: "#ffd700" }}>Gold</span>
        </div>
      </div>
    </div>
  );
}

// ── Position Card ─────────────────────────────────────────────────────────────
function PositionCard({ pos, id, onCompound, onClose, onAdjust, loading, onAlerts }) {
  const [showChart,  setShowChart]  = useState(true);
  const [adjustOpen, setAdjustOpen] = useState(false);
  const [adjLow,     setAdjLow]     = useState("");
  const [adjHigh,    setAdjHigh]    = useState("");
  const [adjAiRange, setAdjAiRange] = useState(null);

  const priceLo   = tickToPrice(Number(pos.tickLower));
  const priceHi   = tickToPrice(Number(pos.tickUpper));
  const midPrice  = Math.sqrt(priceLo * priceHi);
  const sp        = Number(pos.poolKey?.tickSpacing || 10);
  const status    = STATUS_LABEL[Number(pos.status)] ?? "Unknown";
  const isAI      = pos.aiManaged;

  const {
    current, history, entryPrice,
    inRange, nearLower, nearUpper,
    ilPct, simFees, pctFromEntry,
    alerts, dismissAlert,
  } = usePositionHealth(priceLo, priceHi);

  // Lift alerts to parent for the global alert center
  useEffect(() => {
    if (alerts.length > 0) onAlerts?.(id, alerts);
  }, [alerts, id, onAlerts]);

  // Fees earned (on-chain) + simulated accumulation since last compound
  const fees0 = parseFloat(fmt18(pos.totalFees0));
  const fees1 = parseFloat(fmt18(pos.totalFees1));
  const totalSimFeesPct = simFees.toFixed(3);

  // Net P&L: accumulated fees % - IL %
  const netPnl = simFees * 100 + ilPct; // simFees as % of capital

  // IL value estimated from simulated price
  const capital0 = parseFloat(fmt18(pos.initialCapital0));
  const ilAmount = capital0 > 0 ? Math.abs(ilPct / 100) * capital0 : 0;

  const statusColor = {
    Active:     "#10b981",
    OutOfRange: "#f59e0b",
    Closed:     "#6b7280",
  }[status] ?? "#6b7280";

  const openAdjust = useCallback(() => {
    setAdjLow(priceLo.toFixed(6));
    setAdjHigh(priceHi.toFixed(6));
    setAdjAiRange({ priceLower: priceLo, priceUpper: priceHi, confidence: 100 });
    setAdjustOpen(v => !v);
  }, [priceLo, priceHi]);

  const applyAdjust = useCallback(() => {
    onAdjust(id, adjLow, adjHigh, sp);
    setAdjustOpen(false);
  }, [id, adjLow, adjHigh, sp, onAdjust]);

  return (
    <div className={`position-card ${isAI ? "ai-card" : "manual-card"} ${!inRange ? "card-oor" : ""}`}>

      {/* ── Header ── */}
      <div className="pos-header">
        <div className="pos-id-wrap">
          <span className={`pos-mode-badge ${isAI ? "badge-ai" : "badge-manual"}`}>
            {isAI ? "🤖 AI" : "✋ Manual"}
          </span>
          <code className="pos-id">{id.slice(0, 10)}…</code>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
          <button className="btn btn-ghost btn-sm" style={{ fontSize: 11, padding: "3px 8px" }}
            onClick={() => setShowChart(v => !v)}>
            {showChart ? "▴ Chart" : "▾ Chart"}
          </button>
          <span className="pos-status" style={{ color: statusColor }}>● {status}</span>
        </div>
      </div>

      {/* ── Health badges (inline alerts) ── */}
      <HealthBadges inRange={inRange} nearLower={nearLower} nearUpper={nearUpper}
        ilPct={ilPct} simFees={simFees} />

      {/* ── Per-card dismissible alerts ── */}
      <AlertBanner alerts={alerts} onDismiss={dismissAlert} />

      {/* ── Live read-only position chart ── */}
      {showChart && (
        <RangeChart
          readOnly
          midPrice={midPrice}
          lower={String(priceLo)}
          upper={String(priceHi)}
          currentPrice={current}
          priceHistory={history}
        />
      )}

      {/* ── Loyalty gauge ── */}
      <LoyaltyGauge depositTime={pos.depositTime} />

      {/* ── Stats grid ── */}
      <div className="pos-stats">
        <div className="pos-stat">
          <span className="ps-label">Price Range</span>
          <span className="ps-val">{formatPrice(priceLo)} — {formatPrice(priceHi)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Current Price</span>
          <span className={`ps-val ${inRange ? "text-green" : "text-orange"}`}>
            {current.toPrecision(5)}
            <span style={{ fontSize: 10, marginLeft: 4, color: "var(--text-dim)" }}>
              ({pctFromEntry >= 0 ? "+" : ""}{pctFromEntry.toFixed(2)}%)
            </span>
          </span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Capital Token0</span>
          <span className="ps-val">{fmt18(pos.initialCapital0)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Capital Token1</span>
          <span className="ps-val">{fmt18(pos.initialCapital1)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Fees Earned (on-chain)</span>
          <span className="ps-val text-green">{fees0.toFixed(4)} / {fees1.toFixed(4)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Accruing Since Compound</span>
          <span className={`ps-val ${simFees > 1 ? "text-green" : ""}`}>
            +{totalSimFeesPct}% {simFees > 1 && <span className="compound-hint">⚡ Compound Ready</span>}
          </span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">IL% (simulated)</span>
          <span className={`ps-val ${ilPct < -3 ? "text-red" : ilPct < -1 ? "text-orange" : "text-dim"}`}>
            {ilPct.toFixed(3)}%
            {ilPct < -5 && <span className="il-warn"> ⚠️ Critical</span>}
          </span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">IL Amount (est.)</span>
          <span className={`ps-val ${ilPct < -1 ? "text-orange" : "text-dim"}`}>
            ~{ilAmount.toFixed(4)} T0
          </span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Net P&amp;L</span>
          <span className={`ps-val ${netPnl >= 0 ? "text-green" : "text-red"}`}>
            {fmtPct(netPnl, 3)}
          </span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Compounds (on-chain)</span>
          <span className="ps-val">{Number(pos.compoundCount)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Age</span>
          <span className="ps-val">
            {((Date.now() / 1000 - Number(pos.depositTime)) / 86400).toFixed(1)} days
          </span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Risk Profile</span>
          <span className="ps-val">{RISK_LABEL[Number(pos.riskProfile)] ?? "-"}</span>
        </div>
      </div>

      {/* ── Actions ── */}
      <div className="pos-actions">
        {isAI ? (
          <button className="btn btn-ai btn-sm" onClick={() => onCompound(id, true)} disabled={loading}>
            🤖 Auto Compound
          </button>
        ) : (
          <button className={`btn btn-sm ${simFees > 1 ? "btn-primary" : "btn-secondary"}`}
            onClick={() => onCompound(id, false)} disabled={loading}>
            ⟳ Compound Fees {simFees > 1 ? "⚡" : ""}
          </button>
        )}
        <button className={`btn btn-sm ${adjustOpen ? "btn-primary" : (!inRange ? "btn-warn" : "btn-ghost")}`}
          onClick={openAdjust} disabled={loading}>
          {!inRange ? "⚠️ Fix Range" : "↕ Adjust Range"}
        </button>
        <button className="btn btn-danger btn-sm" onClick={() => onClose(id)} disabled={loading}>
          ✕ Close
        </button>
      </div>

      {/* ── Adjust panel ── */}
      {adjustOpen && (
        <div className="adjust-panel">
          {isAI && (
            <div className="adjust-note">
              ⚠️ Manual adjustment overrides AI range until next compound cycle.
            </div>
          )}
          {!inRange && (
            <div className="adjust-note oor-note">
              📍 Position is <strong>out of range</strong> — set a new range that includes the current price{" "}
              <strong>{current.toPrecision(5)}</strong>.
            </div>
          )}
          <RangeChart
            midPrice={midPrice}
            lower={adjLow}
            upper={adjHigh}
            onLower={setAdjLow}
            onUpper={setAdjHigh}
            mode="manual"
            aiRange={adjAiRange}
            tickSpacing={sp}
          />
          <div className="adjust-inputs">
            <div className="form-col">
              <label className="form-label">New Lower Price</label>
              <input className="form-input" type="number"
                value={adjLow} onChange={(e) => setAdjLow(e.target.value)} />
            </div>
            <span className="range-arrow">→</span>
            <div className="form-col">
              <label className="form-label">New Upper Price</label>
              <input className="form-input" type="number"
                value={adjHigh} onChange={(e) => setAdjHigh(e.target.value)} />
            </div>
          </div>
          {(() => {
            try {
              const { tickLower, tickUpper } = priceRangeToTicks(
                parseFloat(adjLow), parseFloat(adjHigh), sp
              );
              const newMid = Math.sqrt(parseFloat(adjLow) * parseFloat(adjHigh));
              const newInRange = current >= parseFloat(adjLow) && current <= parseFloat(adjHigh);
              return (
                <div className="tick-preview" style={{ margin: "8px 0" }}>
                  <span className="tick-label">New Tick Lower</span>
                  <code className="tick-val">{tickLower}</code>
                  <span className="tick-sep">—</span>
                  <span className="tick-label">Tick Upper</span>
                  <code className="tick-val">{tickUpper}</code>
                  <span className="tick-sep">·</span>
                  <span className="tick-label">Width</span>
                  <code className="tick-val">{tickUpper - tickLower} ticks</code>
                  <span className="tick-sep">·</span>
                  <span className="tick-label">Current in new range?</span>
                  <code className="tick-val" style={{ color: newInRange ? "#10b981" : "#ef4444" }}>
                    {newInRange ? "✓ Yes" : "✗ No"}
                  </code>
                </div>
              );
            } catch { return null; }
          })()}
          <div className="adjust-actions">
            <button className="btn btn-primary" onClick={applyAdjust}
              disabled={!adjLow || !adjHigh || loading}>
              ✓ Apply New Range
            </button>
            <button className="btn" style={{ background: "transparent", border: "1px solid var(--border)" }}
              onClick={() => setAdjustOpen(false)}>
              Cancel
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Positions List ───────────────────────────────────────────────────────────
export default function PositionsList({ provider, account, onRefresh }) {
  const [positions, setPositions]   = useState([]);
  const [loading,   setLoading]     = useState(false);
  const [error,     setError]       = useState(null);
  const [txMsg,     setTxMsg]       = useState(null);
  const [globalAlerts, setGlobalAlerts] = useState([]);

  const fetchPositions = useCallback(async () => {
    if (!provider || !account) return;
    setLoading(true); setError(null);
    try {
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, provider);
      const ids = await compounder.getPositionsByOwner(account);
      const details = await Promise.all(
        ids.map(async (id) => ({ id, pos: await compounder.getPosition(id) }))
      );
      setPositions(details.filter((d) => Number(d.pos.status) !== 2));
    } catch (e) { setError(e.message); }
    finally { setLoading(false); }
  }, [provider, account]);

  useEffect(() => {
    fetchPositions();
    const id = setInterval(fetchPositions, 15_000);
    return () => clearInterval(id);
  }, [fetchPositions]);

  const handleAlerts = useCallback((posId, newAlerts) => {
    setGlobalAlerts(prev => {
      const withPos = newAlerts.map(a => ({
        ...a, id: `${posId}-${a.id}`,
        msg: `[${posId.slice(0, 8)}…] ${a.msg}`,
      }));
      // Deduplicate by msg content
      const existing = new Set(prev.map(a => a.msg));
      const fresh = withPos.filter(a => !existing.has(a.msg));
      return [...prev.slice(-6), ...fresh];
    });
  }, []);

  const dismissGlobal = useCallback((id) => {
    setGlobalAlerts(a => a.filter(x => x.id !== id));
  }, []);

  const handleCompound = useCallback(async (id, isAI) => {
    if (!provider) return;
    setTxMsg(null);
    try {
      const signer = await provider.getSigner();
      const c = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);
      const tx = isAI ? await c.autoCompound(id) : await c.compoundManual(id);
      const receipt = await tx.wait();
      setTxMsg(`✅ Compounded — tx ${receipt.hash.slice(0, 14)}…`);
      fetchPositions(); onRefresh?.();
    } catch (e) { setTxMsg(`⚠️ ${e.reason ?? e.shortMessage ?? e.message}`); }
  }, [provider, fetchPositions, onRefresh]);

  const handleClose = useCallback(async (id) => {
    if (!provider || !window.confirm("Close this position and withdraw all funds?")) return;
    setTxMsg(null);
    try {
      const signer = await provider.getSigner();
      const c = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);
      const receipt = await (await c.closePosition(id)).wait();
      setTxMsg(`✅ Closed — tx ${receipt.hash.slice(0, 14)}…`);
      fetchPositions(); onRefresh?.();
    } catch (e) { setTxMsg(`⚠️ ${e.reason ?? e.shortMessage ?? e.message}`); }
  }, [provider, fetchPositions, onRefresh]);

  const handleAdjust = useCallback(async (id, lowPrice, highPrice, tickSpacing = 10) => {
    if (!provider) return;
    setTxMsg(null);
    try {
      const { tickLower, tickUpper } = priceRangeToTicks(
        parseFloat(lowPrice), parseFloat(highPrice), tickSpacing
      );
      const signer = await provider.getSigner();
      const c = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);
      const receipt = await (await c.adjustRange(id, tickLower, tickUpper)).wait();
      setTxMsg(`✅ Range adjusted — tx ${receipt.hash.slice(0, 14)}…`);
      fetchPositions();
    } catch (e) { setTxMsg(`⚠️ ${e.reason ?? e.shortMessage ?? e.message}`); }
  }, [provider, fetchPositions]);

  return (
    <section className="panel">
      <div className="panel-title-row">
        <h2 className="panel-title">
          <span className="panel-icon">📋</span> My Positions
          {positions.length > 0 && <span className="pos-count">{positions.length}</span>}
          {globalAlerts.length > 0 && (
            <span className="global-alert-count">{globalAlerts.length} alert{globalAlerts.length > 1 ? "s" : ""}</span>
          )}
        </h2>
        <button className="btn btn-ghost btn-sm" onClick={fetchPositions} disabled={loading}>
          {loading ? "⟳ Loading…" : "⟳ Refresh"}
        </button>
      </div>

      {/* Global alert center */}
      <AlertBanner alerts={globalAlerts} onDismiss={dismissGlobal} />

      {txMsg && (
        <div className={`form-${txMsg.startsWith("✅") ? "success" : "error"}`}
          style={{ marginBottom: 12 }}>
          {txMsg}
        </div>
      )}
      {error && <div className="form-error" style={{ marginBottom: 12 }}>⚠️ {error}</div>}

      {!provider && <div className="empty-state">Connect wallet to see your positions.</div>}
      {provider && !loading && positions.length === 0 && (
        <div className="empty-state">No active positions. Open one in the Open Position tab ↑</div>
      )}

      <div className="positions-list">
        {positions.map(({ id, pos }) => (
          <PositionCard
            key={id} id={id} pos={pos}
            loading={loading}
            onCompound={handleCompound}
            onClose={handleClose}
            onAdjust={handleAdjust}
            onAlerts={handleAlerts}
          />
        ))}
      </div>
    </section>
  );
}
