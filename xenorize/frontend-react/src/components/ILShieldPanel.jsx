import React from "react";
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip,
  ResponsiveContainer, BarChart, Bar, Cell,
} from "recharts";

function fmtUSD(v) {
  const n = parseFloat(v) || 0;
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000)     return `$${(n / 1_000).toFixed(1)}K`;
  return `$${n.toFixed(2)}`;
}

function fmtPct(v) {
  return `${(parseFloat(v) || 0).toFixed(1)}%`;
}

function LoyaltyBadge({ days }) {
  const d = parseInt(days) || 0;
  if (d >= 90) return <span className="loyalty-badge loyalty-badge--gold">2.0x</span>;
  if (d >= 30) return <span className="loyalty-badge loyalty-badge--silver">1.5x</span>;
  return <span className="loyalty-badge loyalty-badge--bronze">1.0x</span>;
}

function ClaimsTable({ claims }) {
  if (!claims || claims.length === 0) {
    return <p className="empty-state">No recent claims</p>;
  }
  return (
    <div className="claims-table-wrap">
      <table className="claims-table">
        <thead>
          <tr>
            <th>LP Address</th>
            <th>Pool</th>
            <th>IL Detected</th>
            <th>Compensated</th>
            <th>Loyalty</th>
            <th>Age</th>
          </tr>
        </thead>
        <tbody>
          {claims.map((c, i) => (
            <tr key={i}>
              <td className="mono">{c.lp}</td>
              <td><span className="pool-tag">{c.pool}</span></td>
              <td className="text-red">{fmtUSD(c.ilUSD)}</td>
              <td className="text-green">{fmtUSD(c.compensation)}</td>
              <td><LoyaltyBadge days={c.loyaltyDays} /></td>
              <td className="text-muted">{c.loyaltyDays}d</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default function ILShieldPanel({ data }) {
  if (!data) return <PanelSkeleton />;

  const {
    activeSnapshots = 0,
    totalClaimsPaid = 0,
    totalILDetected = 0,
    totalCompensated = 0,
    avgLoyaltyDays = 0,
    compensationRatePct = 0,
    ilHistory = [],
    recentClaims = [],
    loyaltyDist = [],
  } = data;

  const coveragePct = totalILDetected > 0
    ? ((totalCompensated / totalILDetected) * 100).toFixed(1)
    : "0.0";

  return (
    <section className="panel il-shield-panel">
      <h2 className="panel-title">
        <span className="panel-icon">⚔️</span> IL Shield
        <span className="panel-badge panel-badge--hook">afterRemoveLiquidity</span>
      </h2>

      {/* Key metrics */}
      <div className="il-metrics-row">
        <div className="il-metric">
          <span className="il-metric__value">{activeSnapshots}</span>
          <span className="il-metric__label">Active Snapshots</span>
          <span className="il-metric__sub">positions being tracked</span>
        </div>
        <div className="il-metric">
          <span className="il-metric__value">{totalClaimsPaid}</span>
          <span className="il-metric__label">Claims Paid</span>
          <span className="il-metric__sub">IL compensations processed</span>
        </div>
        <div className="il-metric il-metric--red">
          <span className="il-metric__value">{fmtUSD(totalILDetected)}</span>
          <span className="il-metric__label">Total IL Detected</span>
          <span className="il-metric__sub">cumulative</span>
        </div>
        <div className="il-metric il-metric--green">
          <span className="il-metric__value">{fmtUSD(totalCompensated)}</span>
          <span className="il-metric__label">Total Compensated</span>
          <span className="il-metric__sub">{coveragePct}% coverage</span>
        </div>
        <div className="il-metric">
          <span className="il-metric__value">{avgLoyaltyDays}d</span>
          <span className="il-metric__label">Avg Position Age</span>
          <span className="il-metric__sub">loyalty baseline</span>
        </div>
        <div className="il-metric il-metric--purple">
          <span className="il-metric__value">{fmtPct(compensationRatePct)}</span>
          <span className="il-metric__label">Avg Compensation Rate</span>
          <span className="il-metric__sub">of IL amount</span>
        </div>
      </div>

      <div className="charts-row">
        {/* IL over time */}
        {ilHistory.length > 0 && (
          <div className="chart-wrap chart-wrap--two-thirds">
            <h3 className="chart-title">IL Detected vs Compensated (7d)</h3>
            <ResponsiveContainer width="100%" height={200}>
              <AreaChart data={ilHistory}>
                <defs>
                  <linearGradient id="ilGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#ef4444" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#ef4444" stopOpacity={0.0} />
                  </linearGradient>
                  <linearGradient id="compGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#10b981" stopOpacity={0.3} />
                    <stop offset="95%" stopColor="#10b981" stopOpacity={0.0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
                <XAxis dataKey="day"  tick={{ fontSize: 10, fill: "#94a3b8" }} />
                <YAxis tick={{ fontSize: 10, fill: "#94a3b8" }} tickFormatter={(v) => `$${(v/1000).toFixed(0)}K`} />
                <Tooltip formatter={(v) => fmtUSD(v)} />
                <Area type="monotone" dataKey="ilDetected"    stroke="#ef4444" fill="url(#ilGrad)"   name="IL Detected" />
                <Area type="monotone" dataKey="compensated"   stroke="#10b981" fill="url(#compGrad)" name="Compensated" />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        )}

        {/* Loyalty distribution */}
        {loyaltyDist.length > 0 && (
          <div className="chart-wrap chart-wrap--third">
            <h3 className="chart-title">Loyalty Distribution</h3>
            <ResponsiveContainer width="100%" height={200}>
              <BarChart data={loyaltyDist} barSize={22}>
                <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
                <XAxis dataKey="tier"   tick={{ fontSize: 10, fill: "#94a3b8" }} />
                <YAxis tick={{ fontSize: 10, fill: "#94a3b8" }} />
                <Tooltip />
                <Bar dataKey="count" radius={[4, 4, 0, 0]}>
                  {loyaltyDist.map((entry, i) => (
                    <Cell key={i} fill={["#cd7f32", "#c0c0c0", "#ffd700"][i] || "#6366f1"} />
                  ))}
                </Bar>
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
      </div>

      {/* How it works */}
      <div className="il-how-it-works">
        <h3 className="chart-title">How IL Shield Works</h3>
        <div className="il-flow">
          <div className="il-flow__step">
            <div className="il-flow__icon">➕</div>
            <div className="il-flow__label">LP Adds Liquidity</div>
            <div className="il-flow__sub">Hook records entry price snapshot</div>
          </div>
          <div className="il-flow__arrow">→</div>
          <div className="il-flow__step">
            <div className="il-flow__icon">⏱️</div>
            <div className="il-flow__label">Time Passes</div>
            <div className="il-flow__sub">Loyalty score builds (max 100% at 90d)</div>
          </div>
          <div className="il-flow__arrow">→</div>
          <div className="il-flow__step">
            <div className="il-flow__icon">📉</div>
            <div className="il-flow__label">LP Removes Liquidity</div>
            <div className="il-flow__sub">Hook computes HODL vs LP exit value</div>
          </div>
          <div className="il-flow__arrow">→</div>
          <div className="il-flow__step il-flow__step--highlight">
            <div className="il-flow__icon">💸</div>
            <div className="il-flow__label">IL Compensated</div>
            <div className="il-flow__sub">Up to 50% of IL paid from vault</div>
          </div>
        </div>
      </div>

      {/* Recent claims */}
      <div className="chart-wrap">
        <h3 className="chart-title">Recent IL Claims</h3>
        <ClaimsTable claims={recentClaims} />
      </div>
    </section>
  );
}

function PanelSkeleton() {
  return (
    <section className="panel">
      <h2 className="panel-title"><span className="panel-icon">⚔️</span> IL Shield</h2>
      <div className="skeleton-grid">
        {[...Array(6)].map((_, i) => <div key={i} className="skeleton-card" />)}
      </div>
    </section>
  );
}
