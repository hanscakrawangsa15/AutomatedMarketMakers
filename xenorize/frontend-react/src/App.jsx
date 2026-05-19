import React, { useState, useEffect } from "react";
import Header              from "./components/Header.jsx";
import ContractsPanel      from "./components/ContractsPanel.jsx";
import InsuranceFundPanel  from "./components/InsuranceFundPanel.jsx";
import FeeHookPanel        from "./components/FeeHookPanel.jsx";
import AutoCompounderPanel from "./components/AutoCompounderPanel.jsx";
import OpenPositionPanel   from "./components/OpenPositionPanel.jsx";
import PositionsList       from "./components/PositionsList.jsx";
import AIStatusPanel       from "./components/AIStatusPanel.jsx";
import PriceTicker         from "./components/PriceTicker.jsx";
import ILShieldPanel       from "./components/ILShieldPanel.jsx";
import { generateDemoData } from "./components/DemoMode.jsx";
import { useProvider }      from "./lib/useProvider.js";
import { useContractData }  from "./lib/useContractData.js";
import { usePrices }        from "./lib/usePrices.js";

const TABS = ["Overview", "Open Position", "My Positions", "AI Status"];

export default function App() {
  const { provider, account, chainId, error: connErr, connecting,
          connectMetaMask, connectAnvil, disconnect } = useProvider();

  const { data: liveData, loading, error: dataErr, refresh } = useContractData(provider);

  // Always-on real price feed — Binance only
  const { prices, loading: priceLoading, error: priceError, lastUpdated } = usePrices();

  const [demo, setDemo]       = useState(() => generateDemoData(null));
  const [useDemo, setUseDemo] = useState(true);
  const [tab, setTab]         = useState("Overview");

  // Regenerate demo data anchored to real prices whenever prices update
  useEffect(() => {
    if (useDemo) {
      setDemo(generateDemoData(prices));
    }
  }, [prices, useDemo]);

  // Also tick demo data every 15s (between price updates)
  useEffect(() => {
    if (!useDemo) return;
    const id = setInterval(() => setDemo(generateDemoData(prices)), 15_000);
    return () => clearInterval(id);
  }, [useDemo, prices]);

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

      {/* Always-on live price ticker — Binance */}
      <PriceTicker
        prices={prices}
        loading={priceLoading}
        error={priceError}
        lastUpdated={lastUpdated}
      />

      {(connErr || dataErr) && (
        <div className="error-bar">⚠️ {connErr || dataErr}</div>
      )}
      {useDemo && (
        <div className="demo-bar">
          🎭 Demo mode — on-chain data simulated. Prices above are <strong>live from CoinGecko</strong>.
          Connect MetaMask or Anvil to read live chain state.
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
                { label: "Total TVL", value: `$${parseFloat(data?.compounder?.tvl||0).toLocaleString("en-US", { maximumFractionDigits: 0 })}`, icon: "💹" },
                { label: "Open Positions", value: data?.compounder?.positions ?? "—", icon: "🔖" },
                { label: "Vault Assets", value: `$${parseFloat(data?.insurance?.totalAssets||0).toLocaleString("en-US", { maximumFractionDigits: 0 })}`, icon: "🛡️" },
                { label: "IL Compensated", value: `$${parseFloat(data?.insurance?.totalPaidOut||0).toLocaleString("en-US", { maximumFractionDigits: 0 })}`, icon: "⚔️" },
                { label: "Active Snapshots", value: data?.ilShield?.activeSnapshots ?? "—", icon: "📸" },
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

            <ILShieldPanel data={data?.ilShield} />

            <AutoCompounderPanel data={data?.compounder} />

            <div className="footer-bar">
              {!useDemo && (
                <button className="btn btn-ghost" onClick={refresh} disabled={loading}>
                  {loading ? "⟳ Refreshing…" : "⟳ Refresh"}
                </button>
              )}
              <span className="footer-note">
                {useDemo
                  ? `Demo on-chain data • Prices live from CoinGecko (updated ${lastUpdated?.toLocaleTimeString() ?? "…"})`
                  : "Live chain data — auto-refreshes every 15 s"}
              </span>
            </div>
          </>
        )}

        {/* ── Open Position ──────────────────────────────────── */}
        {tab === "Open Position" && (
          <OpenPositionPanel provider={provider} account={account} prices={prices} />
        )}

        {/* ── My Positions ───────────────────────────────────── */}
        {tab === "My Positions" && (
          <PositionsList provider={provider} account={account} onRefresh={refresh} />
        )}

        {/* ── AI Status ──────────────────────────────────────── */}
        {tab === "AI Status" && (
          <AIStatusPanel data={data} prices={prices} />
        )}

      </main>
    </div>
  );
}
