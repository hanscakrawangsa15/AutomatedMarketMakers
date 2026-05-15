import React from "react";
import {
  PieChart, Pie, Cell, Tooltip, ResponsiveContainer, Legend,
} from "recharts";
import StatCard from "./StatCard.jsx";

const COLORS = ["#6366f1", "#22d3ee", "#f59e0b", "#10b981"];

export default function InsuranceFundPanel({ data }) {
  if (!data) return <PanelSkeleton />;

  const pieData = [
    { name: "Balance token0", value: parseFloat(data.balance0) || 0 },
    { name: "Balance token1", value: parseFloat(data.balance1) || 0 },
    { name: "Paid out token0", value: parseFloat(data.totalPaidOut0) || 0 },
  ].filter((d) => d.value > 0);

  const utilizationPct = data.totalDeposited0 > 0
    ? ((parseFloat(data.totalPaidOut0) / parseFloat(data.totalDeposited0)) * 100).toFixed(1)
    : "0.0";

  return (
    <section className="panel">
      <h2 className="panel-title">
        <span className="panel-icon">🛡️</span> Insurance Fund
      </h2>

      <div className="stat-grid">
        <StatCard icon="💰" title="Fund Balance token0"  value={`${data.balance0}`}        sub="WAD units" />
        <StatCard icon="💎" title="Fund Balance token1"  value={`${data.balance1}`}        sub="WAD units" />
        <StatCard icon="📤" title="Total Paid Out token0" value={`${data.totalPaidOut0}`}  sub="cumulative" accent="orange" />
        <StatCard icon="📥" title="Total Deposited token0" value={`${data.totalDeposited0}`} sub="cumulative" />
        <StatCard icon="📊" title="Total TVL"            value={`${data.tvl}`}             sub="WAD units" accent="green" />
        <StatCard icon="⚡" title="Utilization"          value={`${utilizationPct}%`}      sub="paid / deposited" />
      </div>

      {pieData.length > 0 && (
        <div className="chart-wrap">
          <h3 className="chart-title">Fund Composition</h3>
          <ResponsiveContainer width="100%" height={220}>
            <PieChart>
              <Pie data={pieData} dataKey="value" nameKey="name" cx="50%" cy="50%" outerRadius={80} label>
                {pieData.map((_, i) => (
                  <Cell key={i} fill={COLORS[i % COLORS.length]} />
                ))}
              </Pie>
              <Tooltip formatter={(v) => v.toFixed(4)} />
              <Legend />
            </PieChart>
          </ResponsiveContainer>
        </div>
      )}
    </section>
  );
}

function PanelSkeleton() {
  return (
    <section className="panel">
      <h2 className="panel-title"><span className="panel-icon">🛡️</span> Insurance Fund</h2>
      <div className="skeleton-grid">
        {[...Array(6)].map((_, i) => <div key={i} className="skeleton-card" />)}
      </div>
    </section>
  );
}
