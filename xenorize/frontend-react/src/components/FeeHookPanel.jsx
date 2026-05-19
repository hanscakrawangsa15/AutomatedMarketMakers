import React, { useState } from "react";
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip,
  ResponsiveContainer, Cell,
} from "recharts";
import StatCard from "./StatCard.jsx";

const FEE_COLORS = ["#6366f1", "#22d3ee", "#10b981"];

function feePct(fee) {
  return fee > 0 ? `${(fee / 10000).toFixed(4)}%` : "—";
}

function fmtUSD(v) {
  const n = parseFloat(v);
  if (isNaN(n)) return "—";
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000)     return `$${(n / 1_000).toFixed(1)}K`;
  return `$${n.toFixed(2)}`;
}

export default function FeeHookPanel({ data }) {
  if (!data) return <PanelSkeleton />;

  const barData = (data.pools ?? []).map((p) => ({
    name: p.name,
    fee: p.fee,
    feePct: p.fee / 100,
    tvlUSD: parseFloat(p.tvlUSD),
  }));

  return (
    <section className="panel">
      <h2 className="panel-title">
        <span className="panel-icon">⚙️</span> Dynamic Fee Hook
        {data.paused && <span className="badge badge-red ml-2">PAUSED</span>}
      </h2>

      <div className="stat-grid">
        <StatCard icon="🎯" title="Base Fee"          value={feePct(data.baseFee)}                           sub="default fee tier" />
        <StatCard icon="📈" title="Target Volatility" value={`${(data.targetVolBps / 100).toFixed(1)}%`}    sub="annualised BPS" />
        <StatCard icon="🤖" title="MEV Threshold"     value={`${(data.mevThresholdBps / 100).toFixed(2)}%`} sub="of pool TVL" accent="orange" />
        <StatCard icon={data.paused ? "🔴" : "🟢"} title="Status" value={data.paused ? "Paused" : "Active"} accent={data.paused ? "red" : "green"} />
      </div>

      {barData.length > 0 && (
        <div className="chart-wrap">
          <h3 className="chart-title">Current Fee by Pool (BPS)</h3>
          <ResponsiveContainer width="100%" height={220}>
            <BarChart data={barData} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="#2a2a3a" />
              <XAxis dataKey="name" tick={{ fill: "#a0a0b0", fontSize: 12 }} />
              <YAxis tick={{ fill: "#a0a0b0", fontSize: 12 }} unit=" bps" />
              <Tooltip
                contentStyle={{ background: "#1a1a2e", border: "1px solid #2a2a3a", borderRadius: 8 }}
                labelStyle={{ color: "#e0e0f0" }}
                formatter={(v) => [`${v} BPS (${(v / 100).toFixed(4)}%)`, "Fee"]}
              />
              <Bar dataKey="fee" radius={[4, 4, 0, 0]}>
                {barData.map((_, i) => (
                  <Cell key={i} fill={FEE_COLORS[i % FEE_COLORS.length]} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}

      <div className="pool-table-wrap">
        <h3 className="chart-title">Pool Details</h3>
        <table className="pool-table">
          <thead>
            <tr>
              <th>Pool</th>
              <th>Price (USD)</th>
              <th>24h Δ</th>
              <th>Current Fee</th>
              <th>TVL (USD)</th>
              <th>Pool ID</th>
            </tr>
          </thead>
          <tbody>
            {(data.pools ?? []).map((p) => {
              const change = p.change24h ?? 0;
              const up     = change >= 0;
              return (
                <tr key={p.id}>
                  <td className="pool-name">{p.name}</td>
                  <td className="price-cell">
                    {p.priceUSD ? `$${p.priceUSD.toLocaleString("en-US", { maximumFractionDigits: 2 })}` : "—"}
                  </td>
                  <td className={up ? "ticker-up" : "ticker-down"}>
                    {p.change24h != null
                      ? `${up ? "+" : ""}${change.toFixed(2)}%`
                      : "—"}
                  </td>
                  <td className="fee-cell">{feePct(p.fee)}</td>
                  <td>{fmtUSD(p.tvlUSD)}</td>
                  <td className="addr-cell">{p.id.slice(0, 10)}…</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}

function PanelSkeleton() {
  return (
    <section className="panel">
      <h2 className="panel-title"><span className="panel-icon">⚙️</span> Dynamic Fee Hook</h2>
      <div className="skeleton-grid">
        {[...Array(4)].map((_, i) => <div key={i} className="skeleton-card" />)}
      </div>
    </section>
  );
}
