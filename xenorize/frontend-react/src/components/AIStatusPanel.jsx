import React, { useState, useEffect } from "react";
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip,
  ResponsiveContainer, ReferenceLine,
} from "recharts";
import { tickToPrice, formatPrice } from "../lib/tickMath.js";

// Simulates keeper activity — in production this comes from on-chain events or a keeper API
function useKeeperActivity() {
  const [activity, setActivity] = useState([]);
  const [nextRun,  setNextRun]  = useState(null);

  useEffect(() => {
    const INTERVAL_MS = 12_000; // ~12 s block time
    const acts = ["Scanning positions…", "Checking volatility…", "Idle — no compound needed",
                  "Compound profitable — preparing tx…", "Recording price snapshot…"];

    const tick = () => {
      const msg = acts[Math.floor(Math.random() * acts.length)];
      setActivity((prev) => [
        { time: new Date().toLocaleTimeString(), msg },
        ...prev.slice(0, 9),
      ]);
      setNextRun(Date.now() + INTERVAL_MS);
    };

    tick();
    const id = setInterval(tick, INTERVAL_MS);
    return () => clearInterval(id);
  }, []);

  return { activity, nextRun };
}

// Simulates rolling volatility for the chart
function useVolatilityHistory() {
  const [history, setHistory] = useState(() =>
    Array.from({ length: 20 }, (_, i) => ({
      t: i,
      vol: 2000 + Math.random() * 4000,
      fee: 20 + Math.random() * 60,
    }))
  );

  useEffect(() => {
    const id = setInterval(() => {
      setHistory((prev) => {
        const last = prev[prev.length - 1];
        const newVol = Math.max(500, Math.min(15000, last.vol + (Math.random() - 0.5) * 600));
        const newFee = Math.max(5, Math.min(150, last.fee + (Math.random() - 0.5) * 8));
        return [...prev.slice(1), { t: last.t + 1, vol: newVol, fee: newFee }];
      });
    }, 4000);
    return () => clearInterval(id);
  }, []);

  return history;
}

function Countdown({ targetMs }) {
  const [secs, setSecs] = useState(0);
  useEffect(() => {
    const update = () => setSecs(Math.max(0, Math.round((targetMs - Date.now()) / 1000)));
    update();
    const id = setInterval(update, 1000);
    return () => clearInterval(id);
  }, [targetMs]);
  return <span>{secs}s</span>;
}

export default function AIStatusPanel({ data }) {
  const { activity, nextRun } = useKeeperActivity();
  const volHistory             = useVolatilityHistory();

  const latestVol = volHistory[volHistory.length - 1]?.vol ?? 3000;
  const latestFee = volHistory[volHistory.length - 1]?.fee ?? 30;

  const urgency = latestVol > 8000 ? "High" : latestVol > 4000 ? "Medium" : "Low";
  const urgencyColor = { High: "#ef4444", Medium: "#f59e0b", Low: "#10b981" }[urgency];

  return (
    <section className="panel ai-status-panel">
      <h2 className="panel-title">
        <span className="panel-icon">🤖</span> AI Keeper Status
        <span className="live-badge">LIVE</span>
      </h2>

      {/* Status row */}
      <div className="ai-status-row">
        <div className="ai-stat-box">
          <span className="ai-stat-label">Compound Urgency</span>
          <span className="ai-stat-val" style={{ color: urgencyColor }}>
            ● {urgency}
          </span>
        </div>
        <div className="ai-stat-box">
          <span className="ai-stat-label">Current Volatility</span>
          <span className="ai-stat-val">{(latestVol / 100).toFixed(1)}%</span>
        </div>
        <div className="ai-stat-box">
          <span className="ai-stat-label">Suggested Fee</span>
          <span className="ai-stat-val primary">{(latestFee / 10000).toFixed(4)}%</span>
        </div>
        <div className="ai-stat-box">
          <span className="ai-stat-label">Next Scan</span>
          <span className="ai-stat-val dim">
            {nextRun ? <Countdown targetMs={nextRun} /> : "—"}
          </span>
        </div>
        <div className="ai-stat-box">
          <span className="ai-stat-label">AI Positions</span>
          <span className="ai-stat-val">{data?.compounder?.positions ?? 0}</span>
        </div>
      </div>

      {/* Vol + Fee chart */}
      <div className="chart-wrap" style={{ marginTop: 20 }}>
        <h3 className="chart-title">Rolling Volatility (BPS) & Dynamic Fee (BPS)</h3>
        <ResponsiveContainer width="100%" height={200}>
          <LineChart data={volHistory} margin={{ top: 4, right: 12, bottom: 4, left: 0 }}>
            <CartesianGrid strokeDasharray="3 3" stroke="#2a2a3a" />
            <XAxis dataKey="t" hide />
            <YAxis yAxisId="vol" tick={{ fill: "#a0a0b0", fontSize: 11 }} unit=" bps" domain={[0, 15000]} />
            <YAxis yAxisId="fee" orientation="right" tick={{ fill: "#a0a0b0", fontSize: 11 }} unit=" bps" domain={[0, 200]} />
            <Tooltip
              contentStyle={{ background: "#1a1a2e", border: "1px solid #2a2a3a", borderRadius: 8 }}
              labelStyle={{ color: "#e0e0f0" }}
              formatter={(v, name) => [
                `${v.toFixed(1)} BPS (${(v / 100).toFixed(2)}%)`,
                name === "vol" ? "Volatility" : "Fee"
              ]}
            />
            <ReferenceLine yAxisId="vol" y={3000} stroke="#6366f166" strokeDasharray="4 4" label={{ value: "Target vol", fill: "#6366f1", fontSize: 10 }} />
            <Line yAxisId="vol" type="monotone" dataKey="vol" stroke="#6366f1" dot={false} strokeWidth={2} name="vol" />
            <Line yAxisId="fee" type="monotone" dataKey="fee" stroke="#22d3ee" dot={false} strokeWidth={2} name="fee" />
          </LineChart>
        </ResponsiveContainer>
      </div>

      {/* Keeper activity log */}
      <div className="keeper-log">
        <h3 className="chart-title">Keeper Activity Log</h3>
        <div className="log-entries">
          {activity.map((a, i) => (
            <div key={i} className={`log-entry ${i === 0 ? "log-latest" : ""}`}>
              <span className="log-time">{a.time}</span>
              <span className="log-msg">{a.msg}</span>
            </div>
          ))}
        </div>
      </div>

      {/* How AI works */}
      <div className="ai-explanation">
        <h3 className="chart-title">How AI Management Works</h3>
        <div className="ai-steps">
          {[
            { icon: "📡", step: "1. Price Recording", desc: "Keeper calls oracle.recordPrice() every block to build volatility history." },
            { icon: "📊", step: "2. Volatility Calculation", desc: "Oracle computes 7-sample rolling std-dev of price returns → annualised vol BPS." },
            { icon: "🎯", step: "3. Range Suggestion", desc: "oracle.getSuggestedRange() computes optimal ticks based on vol × horizon × risk profile." },
            { icon: "⚙️", step: "4. Dynamic Fee", desc: "DynamicFeeHook reads vol from oracle and adjusts fee on every swap in real-time." },
            { icon: "🔄", step: "5. Auto Compound", desc: "Keeper calls autoCompound() when fees exceed gas cost. AI re-centres liquidity at new range." },
            { icon: "🛡️", step: "6. IL Insurance", desc: "On each compound, IL is measured and recorded. Claims submitted to InsuranceFund if IL threshold is crossed." },
          ].map(({ icon, step, desc }) => (
            <div key={step} className="ai-step">
              <span className="ai-step-icon">{icon}</span>
              <div>
                <p className="ai-step-title">{step}</p>
                <p className="ai-step-desc">{desc}</p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
