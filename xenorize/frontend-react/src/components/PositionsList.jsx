import React, { useState, useEffect, useCallback } from "react";
import { Contract, formatUnits } from "ethers";
import { ADDRESSES, AUTO_COMPOUNDER_ABI } from "../lib/contracts.js";
import { tickToPrice, formatPrice } from "../lib/tickMath.js";

const STATUS_LABEL = ["Active", "OutOfRange", "Closed"];
const STATUS_COLOR = { Active: "#10b981", OutOfRange: "#f59e0b", Closed: "#6b7280" };
const RISK_LABEL   = ["Conservative", "Balanced", "Aggressive"];

function fmt18(v) {
  try { return parseFloat(formatUnits(v, 18)).toFixed(4); } catch { return "0"; }
}

function PositionCard({ pos, id, onCompound, onClose, onAdjust, loading }) {
  const [adjustOpen, setAdjustOpen] = useState(false);
  const [newLow, setNewLow]         = useState("");
  const [newHigh, setNewHigh]       = useState("");

  const priceLower = formatPrice(tickToPrice(Number(pos.tickLower)));
  const priceUpper = formatPrice(tickToPrice(Number(pos.tickUpper)));
  const status     = STATUS_LABEL[Number(pos.status)] ?? "Unknown";
  const isAI       = pos.aiManaged;
  const cycle      = Number(pos.compoundCount);
  const ageDays    = ((Date.now() / 1000 - Number(pos.depositTime)) / 86400).toFixed(1);

  return (
    <div className={`position-card ${isAI ? "ai-card" : "manual-card"}`}>
      {/* Header row */}
      <div className="pos-header">
        <div className="pos-id-wrap">
          <span className={`pos-mode-badge ${isAI ? "badge-ai" : "badge-manual"}`}>
            {isAI ? "🤖 AI" : "✋ Manual"}
          </span>
          <code className="pos-id">{id.slice(0, 10)}…</code>
        </div>
        <span
          className="pos-status"
          style={{ color: STATUS_COLOR[status] }}
        >
          ● {status}
        </span>
      </div>

      {/* Stats grid */}
      <div className="pos-stats">
        <div className="pos-stat">
          <span className="ps-label">Price Range</span>
          <span className="ps-val">{priceLower} — {priceUpper}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Ticks</span>
          <span className="ps-val">{pos.tickLower} / {pos.tickUpper}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Capital token0</span>
          <span className="ps-val">{fmt18(pos.initialCapital0)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Capital token1</span>
          <span className="ps-val">{fmt18(pos.initialCapital1)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Fees Earned</span>
          <span className="ps-val green">{fmt18(pos.totalFees0)} / {fmt18(pos.totalFees1)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">IL (token0)</span>
          <span className="ps-val orange">{fmt18(pos.totalIL0)}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Compounds</span>
          <span className="ps-val">{cycle}</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Age</span>
          <span className="ps-val">{ageDays} days</span>
        </div>
        <div className="pos-stat">
          <span className="ps-label">Risk Profile</span>
          <span className="ps-val">{RISK_LABEL[Number(pos.riskProfile)] ?? "-"}</span>
        </div>
      </div>

      {/* Actions */}
      <div className="pos-actions">
        {isAI ? (
          <button
            className="btn btn-ai btn-sm"
            onClick={() => onCompound(id, true)}
            disabled={loading}
          >
            🤖 Auto Compound
          </button>
        ) : (
          <button
            className="btn btn-secondary btn-sm"
            onClick={() => onCompound(id, false)}
            disabled={loading}
          >
            ⟳ Compound Fees
          </button>
        )}

        <button
          className="btn btn-ghost btn-sm"
          onClick={() => setAdjustOpen(!adjustOpen)}
          disabled={loading}
        >
          ↕ Adjust Range
        </button>

        <button
          className="btn btn-danger btn-sm"
          onClick={() => onClose(id)}
          disabled={loading}
        >
          ✕ Close
        </button>
      </div>

      {/* Adjust Range inline form */}
      {adjustOpen && (
        <div className="adjust-form">
          <p className="adjust-note">
            {isAI
              ? "⚠️ AI position: manual adjustment overrides AI until next compound."
              : "Set new price range for your manual position."}
          </p>
          <div className="adjust-inputs">
            <input
              className="form-input"
              type="number"
              placeholder="New lower price"
              value={newLow}
              onChange={(e) => setNewLow(e.target.value)}
            />
            <span className="range-arrow">→</span>
            <input
              className="form-input"
              type="number"
              placeholder="New upper price"
              value={newHigh}
              onChange={(e) => setNewHigh(e.target.value)}
            />
            <button
              className="btn btn-primary btn-sm"
              onClick={() => { onAdjust(id, newLow, newHigh); setAdjustOpen(false); }}
              disabled={!newLow || !newHigh || loading}
            >
              Apply
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

export default function PositionsList({ provider, account, onRefresh }) {
  const [positions, setPositions] = useState([]);
  const [loading, setLoading]     = useState(false);
  const [error, setError]         = useState(null);
  const [txMsg, setTxMsg]         = useState(null);

  const fetchPositions = useCallback(async () => {
    if (!provider || !account) return;
    setLoading(true);
    setError(null);
    try {
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, provider);
      const ids = await compounder.getPositionsByOwner(account);
      const details = await Promise.all(
        ids.map(async (id) => {
          const pos = await compounder.getPosition(id);
          return { id, pos };
        })
      );
      setPositions(details.filter((d) => Number(d.pos.status) !== 2)); // exclude Closed
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, [provider, account]);

  useEffect(() => { fetchPositions(); }, [fetchPositions]);

  const handleCompound = useCallback(async (id, isAI) => {
    if (!provider) return;
    setTxMsg(null);
    try {
      const signer = await provider.getSigner();
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);
      const tx = isAI
        ? await compounder.autoCompound(id)
        : await compounder.compoundManual(id);
      const receipt = await tx.wait();
      setTxMsg(`✅ Compounded — tx ${receipt.hash.slice(0, 14)}…`);
      fetchPositions();
      onRefresh?.();
    } catch (e) {
      setTxMsg(`⚠️ ${e.reason ?? e.message}`);
    }
  }, [provider, fetchPositions, onRefresh]);

  const handleClose = useCallback(async (id) => {
    if (!provider || !window.confirm("Close this position and withdraw all funds?")) return;
    setTxMsg(null);
    try {
      const signer = await provider.getSigner();
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);
      const tx = await compounder.closePosition(id);
      const receipt = await tx.wait();
      setTxMsg(`✅ Closed — tx ${receipt.hash.slice(0, 14)}…`);
      fetchPositions();
      onRefresh?.();
    } catch (e) {
      setTxMsg(`⚠️ ${e.reason ?? e.message}`);
    }
  }, [provider, fetchPositions, onRefresh]);

  const handleAdjust = useCallback(async (id, lowPrice, highPrice) => {
    if (!provider) return;
    setTxMsg(null);
    try {
      const { tickLower, tickUpper } = priceRangeToTicks?.(parseFloat(lowPrice), parseFloat(highPrice)) ?? {};
      const signer = await provider.getSigner();
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, signer);
      const tx = await compounder.adjustRange(id, tickLower, tickUpper);
      const receipt = await tx.wait();
      setTxMsg(`✅ Range adjusted — tx ${receipt.hash.slice(0, 14)}…`);
      fetchPositions();
    } catch (e) {
      setTxMsg(`⚠️ ${e.reason ?? e.message}`);
    }
  }, [provider, fetchPositions]);

  return (
    <section className="panel">
      <div className="panel-title-row">
        <h2 className="panel-title">
          <span className="panel-icon">📋</span> My Positions
          <span className="pos-count">{positions.length}</span>
        </h2>
        <button className="btn btn-ghost btn-sm" onClick={fetchPositions} disabled={loading}>
          {loading ? "⟳…" : "⟳ Refresh"}
        </button>
      </div>

      {txMsg && <div className={`form-${txMsg.startsWith("✅") ? "success" : "error"}`}>{txMsg}</div>}
      {error && <div className="form-error">⚠️ {error}</div>}

      {!provider && (
        <div className="empty-state">Connect wallet to see your positions.</div>
      )}

      {provider && positions.length === 0 && !loading && (
        <div className="empty-state">No active positions. Open one above ↑</div>
      )}

      <div className="positions-list">
        {positions.map(({ id, pos }) => (
          <PositionCard
            key={id}
            id={id}
            pos={pos}
            loading={loading}
            onCompound={handleCompound}
            onClose={handleClose}
            onAdjust={handleAdjust}
          />
        ))}
      </div>
    </section>
  );
}
