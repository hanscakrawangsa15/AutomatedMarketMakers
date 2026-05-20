import React, { useState, useCallback, useRef, useEffect, useMemo } from "react";

// ── Layout ───────────────────────────────────────────────────────────────────
const CHART_H = 320;
const PAD_L   = 58;
const PAD_R   = 16;
const PAD_T   = 22;
const PAD_B   = 26;
const INNER_H = CHART_H - PAD_T - PAD_B;
const HIT     = 14;

// ── Helpers ──────────────────────────────────────────────────────────────────
function fmt(p) {
  if (p == null || isNaN(p)) return "—";
  return p < 0.001 ? p.toExponential(2) : p.toPrecision(5);
}

// Seeded LCG OHLC — used when no external priceHistory is supplied
function seededOHLC(midPrice, count = 52) {
  let p    = midPrice;
  let seed = (midPrice * 1000 | 0) || 42;
  const lcg = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 0xffffffff; };
  return Array.from({ length: count }, () => {
    const open  = p;
    const ticks = [open];
    for (let j = 0; j < 4; j++) {
      p = Math.max(midPrice * 0.3, p * (1 + (lcg() - 0.499) * 0.025));
      ticks.push(p);
    }
    return { open, close: ticks[4], high: Math.max(...ticks), low: Math.min(...ticks) };
  });
}

// Convert a flat price array into OHLC candles (chunk size = 5)
function arrayToOHLC(prices, chunk = 5) {
  const out = [];
  for (let i = 0; i < prices.length; i += chunk) {
    const c = prices.slice(i, i + chunk);
    if (!c.length) continue;
    out.push({ open: c[0], close: c[c.length - 1], high: Math.max(...c), low: Math.min(...c) });
  }
  return out;
}

// Internal live price (used only when no external currentPrice supplied)
function useLivePrice(mid, skip = false) {
  const [price, setPrice] = useState(mid);
  const seedRef = useRef((mid * 9973 | 0) || 7);
  useEffect(() => {
    setPrice(mid);
    seedRef.current = (mid * 9973 | 0) || 7;
  }, [mid]);
  useEffect(() => {
    if (skip) return;
    const id = setInterval(() => {
      seedRef.current = (seedRef.current * 1664525 + 1013904223) >>> 0;
      const r = seedRef.current / 0xffffffff;
      setPrice(p => Math.max(mid * 0.3, p * (1 + (r - 0.499) * 0.018)));
    }, 2200);
    return () => clearInterval(id);
  }, [mid, skip]);
  return price;
}

/**
 * RangeChart – vertical candlestick chart with horizontal range lines.
 *
 * Props:
 *   midPrice      number       – reference/centre price
 *   lower         string       – lower price bound
 *   upper         string       – upper price bound
 *   onLower       fn(string)   – called on lower drag  (ignored when readOnly)
 *   onUpper       fn(string)   – called on upper drag  (ignored when readOnly)
 *   mode          "manual"|"ai"
 *   aiRange       { priceLower, priceUpper, confidence } | null
 *   readOnly      bool         – disables drag; shows static view of the position
 *   currentPrice  number|null  – live price from parent (overrides internal simulation)
 *   priceHistory  number[]|null – 80-point price array → converted to OHLC
 */
export default function RangeChart({
  midPrice = 1,
  lower, upper,
  onLower, onUpper,
  mode         = "manual",
  aiRange      = null,
  readOnly     = false,
  currentPrice = null,
  priceHistory = null,
}) {
  const containerRef = useRef(null);
  const svgRef       = useRef(null);
  const [w, setW]    = useState(680);
  const dragRef      = useRef(null);
  const [cursor, setCursor] = useState("crosshair");

  useEffect(() => {
    if (!containerRef.current) return;
    const ro = new ResizeObserver(([e]) => setW(e.contentRect.width));
    ro.observe(containerRef.current);
    return () => ro.disconnect();
  }, []);

  const mid      = parseFloat(midPrice) || 1;
  const lo       = parseFloat(lower)    || mid * 0.9;
  const hi       = parseFloat(upper)    || mid * 1.1;
  const isManual = mode === "manual" && !readOnly;
  const innerW   = w - PAD_L - PAD_R;

  // Price data: external wins over internal simulation
  const internalLive = useLivePrice(mid, currentPrice !== null);
  const livePrice    = currentPrice !== null ? currentPrice : internalLive;
  const candles      = useMemo(() => {
    if (priceHistory && priceHistory.length > 0) return arrayToOHLC(priceHistory);
    return seededOHLC(mid, 52);
  }, [priceHistory, mid]);

  // ── Y-axis scale ─────────────────────────────────────────────────────────
  // readOnly: centre on range so the green band fills ~65% of chart height
  // editable: include all candle highs/lows so nothing is clipped
  const rangeSpan = hi - lo;
  let vLo, vHi, vSpan;
  if (readOnly) {
    const pad = rangeSpan * 0.38;   // range occupies ≈ 60 % of visible height
    vLo   = lo - pad;
    vHi   = hi + pad;
    vSpan = vHi - vLo;
  } else {
    const allP = [...candles.flatMap(c => [c.high, c.low]), lo, hi, livePrice];
    const pMin = Math.min(...allP);
    const pMax = Math.max(...allP);
    const span = Math.max(pMax - pMin, mid * 0.01);
    vLo   = pMin - span * 0.10;
    vHi   = pMax + span * 0.10;
    vSpan = vHi - vLo;
  }

  const pToY = useCallback((p) => PAD_T + (1 - (p - vLo) / vSpan) * INNER_H, [vLo, vSpan]);

  // ── Candle layout ─────────────────────────────────────────────────────────
  const n       = candles.length;
  const spacing = innerW / Math.max(1, n);
  const candleW = Math.max(2, spacing * 0.55);
  const cToX    = (i) => PAD_L + (i + 0.5) * spacing;

  // ── Y-axis ticks ──────────────────────────────────────────────────────────
  const yTicks = useMemo(() => Array.from({ length: 7 }, (_, i) => {
    const p = vLo + vSpan * i / 6;
    return { p, y: pToY(p) };
  }), [vLo, vSpan, pToY]);

  const loY  = pToY(lo);
  const hiY  = pToY(hi);
  const curY = pToY(livePrice);
  const inRange    = livePrice >= lo && livePrice <= hi;
  const rangeColor = inRange ? "#22c55e" : "#f59e0b";
  const trackColor = readOnly ? rangeColor : (isManual ? "#6366f1" : "#22d3ee");

  // ── SVG Y helper ─────────────────────────────────────────────────────────
  const getSvgY = (e) => {
    const rect = svgRef.current?.getBoundingClientRect();
    if (!rect) return 0;
    const cy = e.touches ? e.touches[0].clientY : e.clientY;
    return cy - rect.top;
  };

  // ── Drag (disabled in readOnly) ───────────────────────────────────────────
  const startDrag = useCallback((e) => {
    if (!isManual) return;
    e.preventDefault();
    const y = getSvgY(e);
    let dmode = null;
    if (Math.abs(y - hiY) <= HIT)            dmode = "upper";
    else if (Math.abs(y - loY) <= HIT)       dmode = "lower";
    else if (y > hiY + HIT && y < loY - HIT) dmode = "band";
    if (!dmode) return;
    dragRef.current = { dmode, startY: y, startLo: lo, startHi: hi };
  }, [isManual, hiY, loY, lo, hi]);

  const doDrag = useCallback((e) => {
    if (!dragRef.current || !isManual) return;
    e.preventDefault();
    const y  = getSvgY(e);
    const dy = y - dragRef.current.startY;
    const dp = -(dy / INNER_H) * vSpan;
    const { dmode, startLo, startHi } = dragRef.current;
    const minGap = mid * 0.001;
    if (dmode === "upper") {
      onUpper(String(Math.max(startLo + minGap, startHi + dp).toFixed(6)));
    } else if (dmode === "lower") {
      onLower(String(Math.min(startHi - minGap, startLo + dp).toFixed(6)));
    } else {
      onLower(String((startLo + dp).toFixed(6)));
      onUpper(String((startHi + dp).toFixed(6)));
    }
  }, [isManual, vSpan, mid, onLower, onUpper]);

  const endDrag = useCallback(() => { dragRef.current = null; }, []);

  useEffect(() => {
    const el = svgRef.current;
    if (!el) return;
    el.addEventListener("touchstart", startDrag, { passive: false });
    el.addEventListener("touchmove",  doDrag,    { passive: false });
    el.addEventListener("touchend",   endDrag);
    return () => {
      el.removeEventListener("touchstart", startDrag);
      el.removeEventListener("touchmove",  doDrag);
      el.removeEventListener("touchend",   endDrag);
    };
  }, [startDrag, doDrag, endDrag]);

  const onSvgMouseMove = useCallback((e) => {
    doDrag(e);
    if (!isManual) { setCursor("default"); return; }
    const y = getSvgY(e);
    if (Math.abs(y - hiY) <= HIT || Math.abs(y - loY) <= HIT) setCursor("ns-resize");
    else if (y > hiY + HIT && y < loY - HIT) setCursor(dragRef.current ? "grabbing" : "grab");
    else setCursor("crosshair");
  }, [doDrag, isManual, hiY, loY]);

  // ── Stats ─────────────────────────────────────────────────────────────────
  const rangePct   = ((hi - lo) / lo * 100).toFixed(1);
  const centerBias = inRange ? ((livePrice - lo) / (hi - lo) * 100).toFixed(0) : null;
  const aiConf     = aiRange?.confidence ?? 0;

  return (
    <div ref={containerRef} className="range-chart-outer">
      {/* Header */}
      <div className="range-chart-header">
        <span className="range-chart-title">
          {readOnly
            ? "📊 Live Position Chart"
            : isManual ? "☝ Drag lines to set range" : "🤖 AI-suggested range"}
        </span>
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          {readOnly && (
            <span style={{
              fontSize: 10, color: "var(--text-dim)",
              background: "#ffffff0a", border: "1px solid var(--border)",
              borderRadius: 4, padding: "2px 8px",
            }}>View Only</span>
          )}
          {aiRange && (
            <span className="ai-confidence-badge">
              Confidence {aiConf}%{" "}
              <span style={{
                display: "inline-block", width: 8, height: 8,
                borderRadius: "50%", background: "#22d3ee",
                marginLeft: 4, verticalAlign: "middle",
              }} />
            </span>
          )}
          <span className={`in-range-dot ${inRange ? "in" : "out"}`} />
        </div>
      </div>

      {/* SVG */}
      <svg
        ref={svgRef}
        width="100%"
        height={CHART_H}
        className="range-chart-svg"
        style={{ cursor: readOnly ? "default" : cursor, userSelect: "none", touchAction: "none" }}
        onMouseDown={readOnly ? undefined : startDrag}
        onMouseMove={onSvgMouseMove}
        onMouseUp={readOnly ? undefined : endDrag}
        onMouseLeave={readOnly ? undefined : endDrag}
      >
        <defs>
          <clipPath id="rcClipV">
            <rect x={PAD_L} y={PAD_T} width={innerW} height={INNER_H} />
          </clipPath>
        </defs>

        {/* Grid */}
        {yTicks.map((t, i) => (
          <line key={i}
            x1={PAD_L} y1={t.y} x2={PAD_L + innerW} y2={t.y}
            stroke="#ffffff07" strokeWidth="1" />
        ))}

        {/* LP range band — more opaque in readOnly for visual prominence */}
        <rect x={PAD_L} y={hiY} width={innerW} height={Math.max(2, loY - hiY)}
          fill={rangeColor} fillOpacity={readOnly ? "0.14" : "0.08"} />

        {/* AI ghost (editable mode only) */}
        {!readOnly && isManual && aiRange && (() => {
          const aHiY = pToY(aiRange.priceUpper);
          const aLoY = pToY(aiRange.priceLower);
          return (
            <>
              <rect x={PAD_L} y={aHiY} width={innerW}
                height={Math.max(1, aLoY - aHiY)}
                fill="#22d3ee" fillOpacity="0.05" />
              <line x1={PAD_L} y1={aHiY} x2={PAD_L + innerW} y2={aHiY}
                stroke="#22d3ee" strokeWidth="1" strokeDasharray="5 3" opacity="0.5" />
              <line x1={PAD_L} y1={aLoY} x2={PAD_L + innerW} y2={aLoY}
                stroke="#22d3ee" strokeWidth="1" strokeDasharray="5 3" opacity="0.5" />
              <text x={PAD_L + 5} y={aHiY - 3} fill="#22d3ee" fontSize="8" opacity="0.6">AI</text>
            </>
          );
        })()}

        {/* Candlesticks */}
        <g clipPath="url(#rcClipV)">
          {candles.map((c, i) => {
            const x       = cToX(i);
            const isGreen = c.close >= c.open;
            const color   = isGreen ? "#22c55e" : "#ef4444";
            const bTop    = pToY(Math.max(c.open, c.close));
            const bBot    = pToY(Math.min(c.open, c.close));
            const bH      = Math.max(1, bBot - bTop);
            const isLast  = i === candles.length - 1;
            return (
              <g key={i} opacity={isLast ? 1 : 0.85}>
                <line x1={x} y1={pToY(c.high)} x2={x} y2={pToY(c.low)}
                  stroke={color} strokeWidth="1" />
                <rect x={x - candleW / 2} y={bTop}
                  width={candleW} height={bH}
                  fill={color} rx="0.5" />
              </g>
            );
          })}
        </g>

        {/* Current price dashed line */}
        <line x1={PAD_L} y1={curY} x2={PAD_L + innerW} y2={curY}
          stroke="#f59e0b" strokeWidth="1.5" strokeDasharray="6 3" opacity="0.9" />
        <rect x={PAD_L + innerW - 62} y={curY - 10} width={60} height={18}
          rx="5" fill="#f59e0b" />
        <text x={PAD_L + innerW - 32} y={curY + 4}
          fill="#0d0d1a" fontSize="9" fontWeight="bold" textAnchor="middle">
          {fmt(livePrice)}
        </text>

        {/* ── Upper boundary ── */}
        <g style={{ cursor: isManual ? "ns-resize" : "default" }}>
          <line x1={PAD_L} y1={hiY} x2={PAD_L + innerW} y2={hiY}
            stroke={trackColor} strokeWidth="2.5" />
          <rect x={PAD_L} y={hiY - 19} width={92} height={17} rx="5"
            fill={trackColor} fillOpacity="0.92" />
          <text x={PAD_L + 46} y={hiY - 7}
            fill="#0d0d1a" fontSize="9" fontWeight="bold" textAnchor="middle">
            ▲ MAX  {fmt(hi)}
          </text>
          {/* Drag knob — hidden in readOnly */}
          {!readOnly && (
            <>
              <circle cx={PAD_L + innerW / 2} cy={hiY} r={7}
                fill={trackColor} stroke="#0d0d1a" strokeWidth="1.5" />
              <line x1={PAD_L + innerW / 2 - 3} y1={hiY}
                    x2={PAD_L + innerW / 2 + 3} y2={hiY}
                stroke="#0d0d1a" strokeWidth="1.5" />
              <line x1={PAD_L + innerW / 2} y1={hiY - 3}
                    x2={PAD_L + innerW / 2} y2={hiY + 3}
                stroke="#0d0d1a" strokeWidth="1.5" />
            </>
          )}
        </g>

        {/* ── Lower boundary ── */}
        <g style={{ cursor: isManual ? "ns-resize" : "default" }}>
          <line x1={PAD_L} y1={loY} x2={PAD_L + innerW} y2={loY}
            stroke={trackColor} strokeWidth="2.5" />
          <rect x={PAD_L} y={loY + 3} width={92} height={17} rx="5"
            fill={trackColor} fillOpacity="0.92" />
          <text x={PAD_L + 46} y={loY + 15}
            fill="#0d0d1a" fontSize="9" fontWeight="bold" textAnchor="middle">
            ▼ MIN  {fmt(lo)}
          </text>
          {!readOnly && (
            <>
              <circle cx={PAD_L + innerW / 2} cy={loY} r={7}
                fill={trackColor} stroke="#0d0d1a" strokeWidth="1.5" />
              <line x1={PAD_L + innerW / 2 - 3} y1={loY}
                    x2={PAD_L + innerW / 2 + 3} y2={loY}
                stroke="#0d0d1a" strokeWidth="1.5" />
              <line x1={PAD_L + innerW / 2} y1={loY - 3}
                    x2={PAD_L + innerW / 2} y2={loY + 3}
                stroke="#0d0d1a" strokeWidth="1.5" />
            </>
          )}
        </g>

        {/* Out-of-range arrows */}
        {livePrice > hi && (
          <text x={PAD_L + innerW / 2} y={PAD_T + 14}
            fill="#f59e0b" fontSize="11" fontWeight="bold" textAnchor="middle">
            ▲ Price above range{!readOnly && " — drag MAX line up"}
          </text>
        )}
        {livePrice < lo && (
          <text x={PAD_L + innerW / 2} y={CHART_H - 8}
            fill="#f59e0b" fontSize="11" fontWeight="bold" textAnchor="middle">
            ▼ Price below range{!readOnly && " — drag MIN line down"}
          </text>
        )}

        {/* Y-axis */}
        <line x1={PAD_L} y1={PAD_T} x2={PAD_L} y2={PAD_T + INNER_H}
          stroke="#252538" strokeWidth="1" />
        {yTicks.map((t, i) => (
          <g key={i}>
            <line x1={PAD_L - 4} y1={t.y} x2={PAD_L} y2={t.y}
              stroke="#252538" strokeWidth="1" />
            <text x={PAD_L - 6} y={t.y + 4}
              fill="#7070a0" fontSize="8" textAnchor="end">
              {t.p.toPrecision(4)}
            </text>
          </g>
        ))}
      </svg>

      {/* Stats bar */}
      <div className="range-stats-bar">
        <div className="range-stat-item">
          <span className="range-stat-label">Range width</span>
          <span className="range-stat-value">{rangePct}%</span>
        </div>
        <div className="range-stat-item">
          <span className="range-stat-label">Price position</span>
          <span className={`range-stat-value ${inRange ? "text-green" : "text-orange"}`}>
            {inRange
              ? `${centerBias}% from low`
              : livePrice > hi ? "Above range ▲" : "Below range ▼"}
          </span>
        </div>
        <div className="range-stat-item">
          <span className="range-stat-label">Min price</span>
          <span className="range-stat-value mono">{fmt(lo)}</span>
        </div>
        <div className="range-stat-item">
          <span className="range-stat-label">Max price</span>
          <span className="range-stat-value mono">{fmt(hi)}</span>
        </div>
        {aiRange && (
          <div className="range-stat-item" style={{ flex: 1.5 }}>
            <span className="range-stat-label">AI confidence</span>
            <div className="ai-conf-bar-wrap">
              <div className="ai-conf-bar-track">
                <div className="ai-conf-bar" style={{ width: `${aiConf}%` }} />
              </div>
              <span className="range-stat-value">{aiConf}%</span>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
