import React from "react";
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, Legend,
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
  if (d >= 90) return <span className="loyalty-badge loyalty-badge--gold">2.0x · Gold</span>;
  if (d >= 30) return <span className="loyalty-badge loyalty-badge--silver">1.5x · Silver</span>;
  return <span className="loyalty-badge loyalty-badge--bronze">1.0x · Bronze</span>;
}

// Tooltip explaining each column in claims table
function ColHelp({ tip }) {
  return (
    <span className="col-help" title={tip}>ⓘ</span>
  );
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
            <th>
              IL Detected
              <ColHelp tip="Total value lost due to impermanent loss vs simply holding" />
            </th>
            <th>
              Eligible Claim
              <ColHelp tip="Max claimable = 50% of IL × loyalty score (0–100% based on position age 0–90d)" />
            </th>
            <th>
              Actual Paid
              <ColHelp tip="Amount actually paid — may be less than eligible if fund health is low or lifetime cap reached" />
            </th>
            <th>Loyalty</th>
            <th>Age</th>
          </tr>
        </thead>
        <tbody>
          {claims.map((c, i) => {
            const gapPct = c.eligible > 0
              ? (((c.eligible - c.compensation) / c.eligible) * 100).toFixed(0)
              : "0";
            return (
              <tr key={i}>
                <td className="mono">{c.lp}</td>
                <td><span className="pool-tag">{c.pool}</span></td>
                <td className="text-red">{fmtUSD(c.ilUSD)}</td>
                <td className="text-orange">
                  {fmtUSD(c.eligible)}
                  <span className="eligible-formula">
                    50% × {fmtPct((Math.min(1, c.loyaltyDays / 90) * 100).toFixed(0))}
                  </span>
                </td>
                <td className="text-green">
                  {fmtUSD(c.compensation)}
                  {gapPct > 0 && (
                    <span className="underpaid-tag">-{gapPct}%</span>
                  )}
                </td>
                <td><LoyaltyBadge days={c.loyaltyDays} /></td>
                <td className="text-muted">{c.loyaltyDays}d</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

// Custom tooltip for the 3-series chart
function ILChartTooltip({ active, payload, label }) {
  if (!active || !payload || !payload.length) return null;
  return (
    <div className="il-chart-tooltip">
      <p className="il-chart-tooltip__day">{label}</p>
      {payload.map((entry) => (
        <p key={entry.dataKey} style={{ color: entry.color }}>
          {entry.name}: {fmtUSD(entry.value)}
        </p>
      ))}
      {payload.length === 3 && (
        <p className="il-chart-tooltip__note">
          Gap = IL not covered by design<br />
          (50% cap + loyalty + fund health)
        </p>
      )}
    </div>
  );
}

export default function ILShieldPanel({ data }) {
  if (!data) return <PanelSkeleton />;

  const {
    activeSnapshots      = 0,
    totalClaimsPaid      = 0,
    totalILDetected      = 0,
    totalEligible        = 0,
    totalCompensated     = 0,
    avgLoyaltyDays       = 0,
    avgLoyaltyScore      = 0,
    compensationRatePct  = 0,
    ilHistory            = [],
    recentClaims         = [],
    loyaltyDist          = [],
  } = data;

  // Coverage = actual paid / IL detected
  const coveragePct = totalILDetected > 0
    ? ((totalCompensated / totalILDetected) * 100).toFixed(1)
    : "0.0";

  // Eligibility rate = eligible / IL detected (what LPs *could* claim)
  const eligibilityPct = totalILDetected > 0
    ? ((totalEligible / totalILDetected) * 100).toFixed(1)
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
        <div className="il-metric il-metric--orange">
          <span className="il-metric__value">{fmtUSD(totalEligible)}</span>
          <span className="il-metric__label">Total Eligible Claim</span>
          <span className="il-metric__sub">{eligibilityPct}% of IL · 50% cap × loyalty</span>
        </div>
        <div className="il-metric il-metric--green">
          <span className="il-metric__value">{fmtUSD(totalCompensated)}</span>
          <span className="il-metric__label">Total Actual Paid</span>
          <span className="il-metric__sub">{coveragePct}% of IL detected</span>
        </div>
        <div className="il-metric">
          <span className="il-metric__value">{avgLoyaltyDays}d</span>
          <span className="il-metric__label">Avg Position Age</span>
          <span className="il-metric__sub">loyalty score ~{parseFloat(avgLoyaltyScore).toFixed(0)}%</span>
        </div>
      </div>

      {/* Gap explanation callout */}
      <div className="il-gap-callout">
        <span className="il-gap-callout__icon">ℹ️</span>
        <div>
          <strong>Why is IL Detected higher than Eligible Claim?</strong>
          <span className="il-gap-callout__text">
            {" "}The fund covers up to <strong>50% of IL</strong>, scaled by your{" "}
            <strong>loyalty score</strong> (0→100% over 90 days). New LPs with &lt;30d
            age receive a fraction of the 50% cap. The remaining gap stays in the vault
            as a solvency reserve for long-term payouts.
          </span>
        </div>
      </div>

      <div className="charts-row">
        {/* 3-series IL chart */}
        {ilHistory.length > 0 && (
          <div className="chart-wrap chart-wrap--two-thirds">
            <h3 className="chart-title">IL Detected vs Eligible Claim vs Actual Paid (7d)</h3>
            <ResponsiveContainer width="100%" height={220}>
              <AreaChart data={ilHistory}>
                <defs>
                  <linearGradient id="ilGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#ef4444" stopOpacity={0.25} />
                    <stop offset="95%" stopColor="#ef4444" stopOpacity={0.0} />
                  </linearGradient>
                  <linearGradient id="eligGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#f59e0b" stopOpacity={0.25} />
                    <stop offset="95%" stopColor="#f59e0b" stopOpacity={0.0} />
                  </linearGradient>
                  <linearGradient id="compGrad" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="5%"  stopColor="#10b981" stopOpacity={0.25} />
                    <stop offset="95%" stopColor="#10b981" stopOpacity={0.0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="#334155" />
                <XAxis dataKey="day"  tick={{ fontSize: 10, fill: "#94a3b8" }} />
                <YAxis tick={{ fontSize: 10, fill: "#94a3b8" }} tickFormatter={(v) => `$${(v/1000).toFixed(0)}K`} />
                <Tooltip content={<ILChartTooltip />} />
                <Legend
                  wrapperStyle={{ fontSize: 11, color: "#94a3b8", paddingTop: 8 }}
                  formatter={(value) => (
                    <span style={{ color: "#94a3b8" }}>{value}</span>
                  )}
                />
                <Area
                  type="monotone" dataKey="ilDetected"
                  stroke="#ef4444" fill="url(#ilGrad)"
                  name="IL Detected"
                  strokeWidth={1.5}
                />
                <Area
                  type="monotone" dataKey="eligibleClaim"
                  stroke="#f59e0b" fill="url(#eligGrad)"
                  name="Eligible Claim (50% × loyalty)"
                  strokeWidth={1.5}
                  strokeDasharray="4 2"
                />
                <Area
                  type="monotone" dataKey="compensated"
                  stroke="#10b981" fill="url(#compGrad)"
                  name="Actual Paid"
                  strokeWidth={1.5}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        )}

        {/* Loyalty distribution */}
        {loyaltyDist.length > 0 && (
          <div className="chart-wrap chart-wrap--third">
            <h3 className="chart-title">Loyalty Distribution</h3>
            <ResponsiveContainer width="100%" height={220}>
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
          <div className="il-flow__step il-flow__step--orange">
            <div className="il-flow__icon">🧮</div>
            <div className="il-flow__label">Eligible Claim Computed</div>
            <div className="il-flow__sub">50% of IL × loyalty score (age/90d)</div>
          </div>
          <div className="il-flow__arrow">→</div>
          <div className="il-flow__step il-flow__step--highlight">
            <div className="il-flow__icon">💸</div>
            <div className="il-flow__label">Actual Paid</div>
            <div className="il-flow__sub">≤ eligible · subject to fund health & $10K lifetime cap</div>
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
