import React, { useState } from "react";
import { ADDRESSES } from "../lib/contracts.js";

function CopyButton({ text }) {
  const [copied, setCopied] = useState(false);
  const copy = () => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };
  return (
    <button className="copy-btn" onClick={copy} title="Copy address">
      {copied ? "✓" : "⧉"}
    </button>
  );
}

const CONTRACT_META = [
  { key: "insuranceFund",  label: "Insurance Fund",    icon: "🛡️", desc: "IL compensation pool" },
  { key: "autoCompounder", label: "Auto Compounder",   icon: "🔄", desc: "V4 position manager" },
  { key: "dynamicFeeHook", label: "Dynamic Fee Hook",  icon: "⚙️", desc: "beforeSwap/afterSwap" },
  { key: "oracle",         label: "Chainlink Oracle",  icon: "📡", desc: "Price + volatility feed" },
];

export default function ContractsPanel() {
  return (
    <section className="panel contracts-panel">
      <h2 className="panel-title"><span className="panel-icon">📋</span> Deployed Contracts</h2>
      <p className="panel-note">
        Update addresses in <code>src/lib/contracts.js</code> after running <code>forge script</code>.
      </p>
      <div className="contract-list">
        {CONTRACT_META.map(({ key, label, icon, desc }) => (
          <div key={key} className="contract-row">
            <span className="contract-icon">{icon}</span>
            <div className="contract-info">
              <span className="contract-label">{label}</span>
              <span className="contract-desc">{desc}</span>
            </div>
            <code className="contract-addr">
              {ADDRESSES[key].slice(0, 10)}…{ADDRESSES[key].slice(-6)}
            </code>
            <CopyButton text={ADDRESSES[key]} />
          </div>
        ))}
      </div>
    </section>
  );
}
