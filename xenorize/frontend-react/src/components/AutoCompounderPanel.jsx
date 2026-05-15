import React from "react";
import {
  RadialBarChart, RadialBar, Tooltip, ResponsiveContainer, Legend,
} from "recharts";
import StatCard from "./StatCard.jsx";

export default function AutoCompounderPanel({ data }) {
  if (!data) return <PanelSkeleton />;

  const tvlPct = data.maxTVLCap > 0
    ? Math.min(100, (parseFloat(data.tvl) / parseFloat(data.maxTVLCap)) * 100)
    : 0;

  const radialData = [
    { name: "TVL Cap", value: 100, fill: "#2a2a3a" },
    { name: "Used",    value: tvlPct, fill: "#6366f1" },
  ];

  return (
    <section className="panel">
      <h2 className="panel-title">
        <span className="panel-icon">🔄</span> Auto Compounder
      </h2>

      <div className="stat-grid">
        <StatCard icon="📊" title="Total TVL"        value={`${data.tvl}`}              sub="WAD units" accent="green" />
        <StatCard icon="🔖" title="Open Positions"   value={data.positions.toString()}  sub="active" />
        <StatCard icon="🏦" title="Protocol Fee"     value={`${(data.protocolFeeBps / 100).toFixed(2)}%`} sub="of compound yield" />
        <StatCard icon="🤖" title="Keeper Reward"    value={`${(data.keeperRewardBps / 100).toFixed(2)}%`} sub="per compound tx" accent="orange" />
        <StatCard icon="📉" title="Min Deposit"      value={`${data.minDepositAmount}`} sub="WAD units" />
        <StatCard icon="🚧" title="Max TVL Cap"      value={`${data.maxTVLCap}`}        sub="WAD units" />
      </div>

      <div className="chart-row">
        <div className="chart-wrap half">
          <h3 className="chart-title">TVL Capacity Used ({tvlPct.toFixed(1)}%)</h3>
          <ResponsiveContainer width="100%" height={200}>
            <RadialBarChart
              cx="50%" cy="50%" innerRadius="60%" outerRadius="90%"
              data={radialData} startAngle={180} endAngle={0}
            >
              <RadialBar dataKey="value" cornerRadius={4} />
              <Tooltip
                contentStyle={{ background: "#1a1a2e", border: "1px solid #2a2a3a", borderRadius: 8 }}
                formatter={(v) => [`${v.toFixed(1)}%`]}
              />
            </RadialBarChart>
          </ResponsiveContainer>
        </div>

        <div className="fee-breakdown half">
          <h3 className="chart-title">Fee Breakdown</h3>
          <div className="fee-row">
            <span className="fee-label">Protocol fee</span>
            <span className="fee-val">{(data.protocolFeeBps / 100).toFixed(2)}%</span>
          </div>
          <div className="fee-row">
            <span className="fee-label">Keeper reward</span>
            <span className="fee-val">{(data.keeperRewardBps / 100).toFixed(2)}%</span>
          </div>
          <div className="fee-row total">
            <span className="fee-label">Total overhead</span>
            <span className="fee-val">
              {((data.protocolFeeBps + data.keeperRewardBps) / 100).toFixed(2)}%
            </span>
          </div>
        </div>
      </div>
    </section>
  );
}

function PanelSkeleton() {
  return (
    <section className="panel">
      <h2 className="panel-title"><span className="panel-icon">🔄</span> Auto Compounder</h2>
      <div className="skeleton-grid">
        {[...Array(6)].map((_, i) => <div key={i} className="skeleton-card" />)}
      </div>
    </section>
  );
}
