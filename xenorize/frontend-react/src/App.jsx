import React, { useState, useEffect } from "react";
import Header              from "./components/Header.jsx";
import ContractsPanel      from "./components/ContractsPanel.jsx";
import InsuranceFundPanel  from "./components/InsuranceFundPanel.jsx";
import FeeHookPanel        from "./components/FeeHookPanel.jsx";
import AutoCompounderPanel from "./components/AutoCompounderPanel.jsx";
import OpenPositionPanel   from "./components/OpenPositionPanel.jsx";
import PositionsList       from "./components/PositionsList.jsx";
import AIStatusPanel       from "./components/AIStatusPanel.jsx";
import { generateDemoData } from "./components/DemoMode.jsx";
import { useProvider }      from "./lib/useProvider.js";
import { useContractData }  from "./lib/useContractData.js";

const TABS = ["Overview", "Open Position", "My Positions", "AI Status"];

export default function App() {
  const { provider, account, chainId, error: connErr, connecting,
          connectMetaMask, connectAnvil, disconnect } = useProvider();

  const { data: liveData, loading, error: dataErr, refresh } = useContractData(provider);

  const [demo, setDemo]       = useState(generateDemoData());
  const [useDemo, setUseDemo] = useState(true);
  const [tab, setTab]         = useState("Overview");

  useEffect(() => {
    if (useDemo) {
      const id = setInterval(() => setDemo(generateDemoData()), 8000);
      return () => clearInterval(id);
    }
  }, [useDemo]);

  useEffect(() => {
    if (provider) setUseDemo(false);
    else          setUseDemo(true);
  }, [provider]);

  const data = useDemo ? demo : liveData;

  return (
    <div className="app">
      <Header
        account={account} chainId={chainId} connecting={connecting}
        onMetaMask={connectMetaMask} onAnvil={connectAnvil} onDisconnect={disconnect}
      />

      {(connErr || dataErr) && (
        <div className="error-bar">⚠️ {connErr || dataErr}</div>
      )}
      {useDemo && (
        <div className="demo-bar">
          🎭 Demo mode — simulated data. Connect MetaMask or Anvil to read live chain state.
        </div>
      )}

      {/* Tab Bar */}
      <nav className="tab-bar">
        {TABS.map((t) => (
          <button
            key={t}
            className={`tab-btn ${tab === t ? "tab-active" : ""}`}
            onClick={() => setTab(t)}
          >
            {t === "Overview"      && "📊 "}
            {t === "Open Position" && "➕ "}
            {t === "My Positions"  && "📋 "}
            {t === "AI Status"     && "🤖 "}
            {t}
          </button>
        ))}
      </nav>

      <main className="main">

        {/* ── Overview ─────────────────────────────────────────── */}
        {tab === "Overview" && (
          <>
            {/* Summary tiles */}
            <div className="summary-row">
              {[
                { label: "Total TVL", value: `${parseFloat(data?.compounder?.tvl||0).toLocaleString()} WAD`, icon: "💹" },
                { label: "Open Positions", value: data?.compounder?.positions ?? "—", icon: "🔖" },
                { label: "Insurance Balance", value: `${parseFloat(data?.insurance?.balance0||0).toLocaleString()} T0`, icon: "🛡️" },
                { label: "Base Fee", value: `${((data?.hook?.baseFee ?? 30)/10000).toFixed(4)}%`, icon: "⚙️" },
                { label: "Hook Status", value: data?.hook?.paused ? "⛔ Paused" : "✅ Active", icon: "🔗" },
              ].map(({ label, value, icon }) => (
                <div key={label} className="summary-tile">
                  <span className="summary-icon">{icon}</span>
                  <div>
                    <p className="summary-label">{label}</p>
                    <p className="summary-value">{value}</p>
                  </div>
                </div>
              ))}
            </div>

            <ContractsPanel />

            <div className="panel-grid">
              <InsuranceFundPanel data={data?.insurance} />
              <FeeHookPanel       data={data?.hook}      />
            </div>

            <AutoCompounderPanel data={data?.compounder} />

            <div className="footer-bar">
              {!useDemo && (
                <button className="btn btn-ghost" onClick={refresh} disabled={loading}>
                  {loading ? "⟳ Refreshing…" : "⟳ Refresh"}
                </button>
              )}
              <span className="footer-note">
                {useDemo ? "Demo data refreshes every 8 s" : "Live data — auto-refreshes every 15 s"}
              </span>
            </div>
          </>
        )}

        {/* ── Open Position ──────────────────────────────────── */}
        {tab === "Open Position" && (
          <OpenPositionPanel provider={provider} account={account} />
        )}

        {/* ── My Positions ───────────────────────────────────── */}
        {tab === "My Positions" && (
          <PositionsList provider={provider} account={account} onRefresh={refresh} />
        )}

        {/* ── AI Status ──────────────────────────────────────── */}
        {tab === "AI Status" && (
          <AIStatusPanel data={data} />
        )}

      </main>
    </div>
  );
}
