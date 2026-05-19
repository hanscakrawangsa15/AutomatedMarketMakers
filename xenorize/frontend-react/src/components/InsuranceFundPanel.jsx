import React from "react";
import {
  PieChart, Pie, Cell, Tooltip, ResponsiveContainer, Legend,
  BarChart, Bar, XAxis, YAxis, CartesianGrid,
} from "recharts";
import StatCard from "./StatCard.jsx";

const COLORS = ["#6366f1", "#22d3ee", "#f59e0b", "#10b981"];

function fmtCompact(raw) {
  const n = parseFloat(raw);
  if (isNaN(n) || n === 0) return "0";
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000)     return `$${(n / 1_000).toFixed(1)}K`;
  return `$${n.toFixed(2)}`;
}

function fmtPct(bps) {
  return `${((bps ?? 0) / 100).toFixed(1)}%`;
}

export default function InsuranceFundPanel({ data }) {
  if (!data) return <PanelSkeleton />;

  const totalAssets   = parseFloat(data.totalAssets)   || 0;
  const feeIncome     = parseFloat(data.totalFeeIncome) || 0;
  const paidOut       = parseFloat(data.totalPaidOut)   || 0;
  const staked        = parseFloat(data.stakedByUsers)  || 0;
  const healthBps     = parseFloat(data.fundHealthBps)  || 0;
  const sharePrice    = parseFloat(data.sharePrice)     || 1;

  const available     = Math.max(0, totalAssets - paidOut);
  const utilizationPct = feeIncome > 0
    ? ((paidOut / feeIncome) * 100).toFixed(1)
    : "0.0";

  const healthColor =
    healthBps >= 2000 ? "#10b981" :
    healthBps >= 1000 ? "#f59e0b" : "#ef4444";

  // Pie: how vault assets are composed
  const pieData = [
    { name: "Protocol Fees",  value: Math.max(0, feeIncome - staked) },
    { name: "Staker Deposits", value: staked  },
    { name: "IL Paid Out",    value: paidOut  },
  ].filter((d) => d.value > 0);

  // Bar: income vs payout
  const barData = [
    { name: "Fee Income",  amount: feeIncome },
    { name: "Staked",      amount: staked    },
    { name: "IL Payouts",  amount: paidOut   },
    { name: "Available",   amount: available },
  ];

  return (
    <section className="panel">
      <h2 className="panel-title">
        <span className="panel-icon">🛡️</span> Insurance Vault
        <span className="panel-badge panel-badge--erc4626">ERC-4626</span>
      </h2>

      <div className="stat-grid">
        <StatCard
          icon="💰" title="Vault Total Assets"
          value={fmtCompact(totalAssets)}
          sub="primary asset (USDC)" accent="green"
        />
        <StatCard
          icon="📈" title="Share Price (NAV)"
          value={`${sharePrice.toFixed(4)}x`}
          sub="per xINS share"
        />
        <StatCard
          icon="📥" title="Protocol Fee Income"
          value={fmtCompact(feeIncome)}
          sub="cumulative fees received"
        />
        <StatCard
          icon="📤" title="IL Compensated"
          value={fmtCompact(paidOut)}
          sub={`${utilizationPct}% utilization`} accent="orange"
        />
        <StatCard
          icon="🏦" title="Staker Deposits"
          value={fmtCompact(staked)}
          sub="ERC-4626 deposits"
        />
        <StatCard
          icon="❤️" title="Fund Health"
          value={fmtPct(healthBps)}
          sub="assets / managed TVL"
          accentColor={healthColor}
        />
      </div>

      {/* Health bar */}
      <div className="fund-health-bar-wrap">
        <div className="fund-health-label">
          <span>Fund Coverage</span>
          <span style={{ color: healthColor }}>{fmtPct(healthBps)}</span>
        </div>
        <div className="fund-health-bar">
          <div
            className="fund-health-fill"
            style={{
              width: `${Math.min(100, healthBps / 100)}%`,
              background: healthColor,
            }}
          />
        </div>
        <div className="fund-health-legend">
          <span style={{ color: "#ef4444" }}>●</span> &lt;10% critical&nbsp;
          <span style={{ color: "#f59e0b" }}>●</span> &lt;20% caution&nbsp;
          <span style={{ color: "#10b981" }}>●</span> ≥20% healthy
        </div>
      </div>

      <div className="charts-row">
        {/* Pie: vault composition */}
        {pieData.length > 0 && (
          <div className="chart-wrap chart-wrap--half">
            <h3 className="chart-title">Vault Composition</h3>
            <ResponsiveContainer width="100%" height={200}>
              <PieChart>
                <Pie
                  data={pieData} dataKey="value" nameKey="name"
                  cx="50%" cy="50%" outerRadius={70}
                  label={({ percent }) => `${(percent * 100).toFixed(0)}%`}
                >
                  {pieData.map((_, i) => (
                    <Cell key={i} fill={COLORS[i % COLORS.length]} />
                  ))}
                </Pie>
                <Tooltip formatter={(v) => fmtCompact(v)} />
                <Legend iconSize={10} />
              </PieChart>
            </ResponsiveContainer>
          </div>
        )}

        {/* Bar: income vs payouts */}
        <div className="chart-wrap chart-wrap--half">
          <h3 className="chart-title">Fund Flow</h3>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart data={barData} barSize={28}>
              <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
              <XAxis dataKey="name" tick={{ fontSize: 10, fill: "#94a3b8" }} />
              <YAxis tick={{ fontSize: 10, fill: "#94a3b8" }} tickFormatter={(v) => `$${(v/1000).toFixed(0)}K`} />
              <Tooltip formatter={(v) => fmtCompact(v)} />
              <Bar dataKey="amount" radius={[4, 4, 0, 0]}>
                {barData.map((entry, i) => (
                  <Cell key={i} fill={COLORS[i % COLORS.length]} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>
      </div>
    </section>
  );
}

function PanelSkeleton() {
  return (
    <section className="panel">
      <h2 className="panel-title"><span className="panel-icon">🛡️</span> Insurance Vault</h2>
      <div className="skeleton-grid">
        {[...Array(6)].map((_, i) => <div key={i} className="skeleton-card" />)}
      </div>
    </section>
  );
}
