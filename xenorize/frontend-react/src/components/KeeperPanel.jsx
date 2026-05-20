import React, { useState, useEffect, useCallback } from "react";

const KEEPER_URL = "/api/keeper/stats";
const POLL_MS    = 5_000;

const LEVEL_COLOR = { info: "#38bdf8", warn: "#fbbf24", error: "#f87171", debug: "#94a3b8" };

function StatCard({ label, value, sub, accent }) {
  return (
    <div style={{
      background: "#1e293b", borderRadius: 10, padding: "14px 18px",
      borderLeft: `3px solid ${accent || "#38bdf8"}`, minWidth: 130,
    }}>
      <div style={{ fontSize: 11, color: "#94a3b8", textTransform: "uppercase", letterSpacing: 1 }}>{label}</div>
      <div style={{ fontSize: 22, fontWeight: 700, color: "#f1f5f9", marginTop: 4 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: "#64748b", marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

export default function KeeperPanel() {
  const [data,    setData]    = useState(null);
  const [error,   setError]   = useState(null);
  const [lastPoll, setLastPoll] = useState(null);

  const poll = useCallback(async () => {
    try {
      const res = await fetch(KEEPER_URL, { signal: AbortSignal.timeout(3000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      setData(json);
      setError(null);
    } catch (e) {
      setError(e.message || "Cannot reach keeper bot");
    }
    setLastPoll(new Date());
  }, []);

  useEffect(() => {
    poll();
    const id = setInterval(poll, POLL_MS);
    return () => clearInterval(id);
  }, [poll]);

  const formatUptime = (s) => {
    if (s == null) return "—";
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${sec}s`;
    return `${sec}s`;
  };

  return (
    <div style={{ padding: "24px 0" }}>
      {/* Header */}
      <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 20 }}>
        <span style={{ fontSize: 22 }}>🤖</span>
        <div>
          <h2 style={{ margin: 0, color: "#f1f5f9", fontSize: 18 }}>Keeper Bot</h2>
          <p style={{ margin: 0, fontSize: 12, color: "#64748b" }}>
            Polls <code style={{ color: "#38bdf8" }}>/api/keeper/stats</code> → proxy → port 8765 · every 5 s
            {lastPoll && ` — last: ${lastPoll.toLocaleTimeString()}`}
          </p>
        </div>
        <div style={{ marginLeft: "auto" }}>
          <span style={{
            display: "inline-flex", alignItems: "center", gap: 6,
            padding: "4px 10px", borderRadius: 20, fontSize: 12,
            background: data ? "#14532d" : "#7f1d1d",
            color: data ? "#86efac" : "#fca5a5",
          }}>
            <span style={{
              width: 7, height: 7, borderRadius: "50%",
              background: data ? "#4ade80" : "#ef4444",
              boxShadow: data ? "0 0 6px #4ade80" : "none",
            }} />
            {data ? "Connected" : error ? "Offline" : "Connecting…"}
          </span>
        </div>
      </div>

      {/* Offline banner */}
      {error && (
        <div style={{
          background: "#450a0a", border: "1px solid #991b1b", borderRadius: 8,
          padding: "12px 16px", color: "#fca5a5", fontSize: 13, marginBottom: 20,
        }}>
          ⚠️ Keeper bot not reachable — <strong>{error}</strong>.
          Make sure the bot is running: <code style={{ color: "#fbbf24" }}>npm run dev</code> in
          <code style={{ color: "#fbbf24" }}> xenorize/keeper-bot/</code>
        </div>
      )}

      {/* Stat cards */}
      {data && (
        <>
          <div style={{ display: "flex", gap: 12, flexWrap: "wrap", marginBottom: 20 }}>
            <StatCard label="Status"     value={data.status === "running" ? "Running" : data.status} accent="#4ade80" />
            <StatCard label="Uptime"     value={formatUptime(data.uptime)} sub="hh mm ss" />
            <StatCard label="Watching"   value={data.watchedCount} sub="positions" />
            <StatCard label="Compounds"  value={data.stats.compoundsTriggered} accent="#818cf8" />
            <StatCard label="Rebalances" value={data.stats.rebalancesTriggered} accent="#fb923c" />
            <StatCard label="Errors"     value={data.stats.errors} accent={data.stats.errors > 0 ? "#f87171" : "#4ade80"} />
            <StatCard label="Gas Spent"  value={`${parseFloat(data.stats.totalGasEth).toFixed(5)} ETH`} accent="#fbbf24" />
          </div>

          {/* Config row */}
          <div style={{
            background: "#1e293b", borderRadius: 10, padding: "12px 16px",
            marginBottom: 20, display: "flex", gap: 24, flexWrap: "wrap", fontSize: 12,
          }}>
            <div>
              <span style={{ color: "#64748b" }}>Keeper address </span>
              <code style={{ color: "#38bdf8" }}>{data.keeper}</code>
            </div>
            <div>
              <span style={{ color: "#64748b" }}>RPC </span>
              <code style={{ color: "#94a3b8" }}>{data.rpc}</code>
            </div>
            <div>
              <span style={{ color: "#64748b" }}>Check interval </span>
              <code style={{ color: "#94a3b8" }}>{data.checkIntervalMs / 1000}s</code>
            </div>
          </div>

          {/* Activity log */}
          <div style={{ background: "#0f172a", borderRadius: 10, overflow: "hidden" }}>
            <div style={{
              padding: "10px 16px", borderBottom: "1px solid #1e293b",
              fontSize: 12, color: "#64748b", fontWeight: 600, textTransform: "uppercase", letterSpacing: 1,
            }}>
              Activity Log (last 20 events)
            </div>
            <div style={{ maxHeight: 340, overflowY: "auto", fontFamily: "monospace", fontSize: 12 }}>
              {data.activity.length === 0 ? (
                <div style={{ padding: "12px 16px", color: "#475569" }}>No activity yet…</div>
              ) : (
                [...data.activity].reverse().map((entry, i) => (
                  <div key={i} style={{
                    display: "flex", gap: 10, padding: "6px 16px",
                    borderBottom: "1px solid #1e293b",
                    background: i % 2 === 0 ? "transparent" : "#0d1a2a",
                  }}>
                    <span style={{ color: "#475569", whiteSpace: "nowrap", flexShrink: 0 }}>
                      {new Date(entry.ts).toLocaleTimeString()}
                    </span>
                    <span style={{
                      color: LEVEL_COLOR[entry.level] || "#94a3b8",
                      fontWeight: 600, width: 44, flexShrink: 0,
                    }}>
                      {entry.level.toUpperCase()}
                    </span>
                    <span style={{ color: "#cbd5e1", wordBreak: "break-all" }}>{entry.msg}</span>
                  </div>
                ))
              )}
            </div>
          </div>
        </>
      )}

      {/* Loading skeleton */}
      {!data && !error && (
        <div style={{ color: "#475569", fontSize: 14, padding: "40px 0", textAlign: "center" }}>
          Connecting to keeper bot…
        </div>
      )}
    </div>
  );
}
