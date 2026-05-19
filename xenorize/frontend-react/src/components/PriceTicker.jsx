import React from "react";

function fmt(sym, n) {
  if (sym === "WBTC")
    return n.toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 0 });
  if (n >= 1000)
    return n.toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 0 });
  return n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

const TOKENS = ["ETH", "WBTC", "LINK", "USDC"];

export default function PriceTicker({ prices, loading, error, lastUpdated }) {
  if (error) {
    return (
      <div className="price-ticker price-ticker--error">
        ⚠️ Price feed unavailable — {error}
      </div>
    );
  }

  return (
    <div className="price-ticker">
      <span className="ticker-label">LIVE PRICES</span>

      <div className="ticker-items">
        {TOKENS.map((sym) => {
          const p = prices?.[sym];
          if (loading || !p) {
            return (
              <span key={sym} className="ticker-item ticker-loading">
                <span className="ticker-sym">{sym}</span>
                <span className="ticker-price ticker-skeleton">$——</span>
              </span>
            );
          }
          const up = p.change24h >= 0;
          return (
            <span key={sym} className="ticker-item">
              <span className="ticker-sym">{sym}</span>
              <span
                className={`ticker-price ${p.direction === "up" ? "flash-up" : p.direction === "down" ? "flash-down" : ""}`}
              >
                ${fmt(sym, p.usd)}
              </span>
              <span className={`ticker-change ${up ? "ticker-up" : "ticker-down"}`}>
                {up ? "▲" : "▼"} {Math.abs(p.change24h).toFixed(2)}%
              </span>
            </span>
          );
        })}
      </div>

      <span className="ticker-updated">
        {loading ? "⟳ loading…" : (
          <>
            <span className="ticker-dot">●</span>
            {" "}CoinGecko · {lastUpdated?.toLocaleTimeString()}
          </>
        )}
      </span>
    </div>
  );
}
