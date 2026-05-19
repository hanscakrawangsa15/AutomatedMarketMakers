import { useState, useEffect, useRef } from "react";

const COINGECKO =
  "https://api.coingecko.com/api/v3/simple/price" +
  "?ids=ethereum,bitcoin,chainlink,usd-coin" +
  "&vs_currencies=usd&include_24hr_change=true&include_24hr_vol=true";

const ID_MAP = {
  ethereum:   "ETH",
  bitcoin:    "WBTC",
  chainlink:  "LINK",
  "usd-coin": "USDC",
};

function timedFetch(url, ms = 10000) {
  const ctrl = new AbortController();
  const id   = setTimeout(() => ctrl.abort(), ms);
  return fetch(url, { signal: ctrl.signal }).finally(() => clearTimeout(id));
}

async function fetchCoinGecko() {
  const res = await timedFetch(COINGECKO);
  if (!res.ok) throw new Error(`CoinGecko ${res.status}`);
  const raw = await res.json();

  const out = {};
  for (const [id, sym] of Object.entries(ID_MAP)) {
    const d = raw[id];
    if (d) out[sym] = { usd: d.usd, change24h: d.usd_24h_change ?? 0 };
  }
  if (!out.ETH) throw new Error("CoinGecko: ETH missing");
  return out;
}

// ─── React hook ───────────────────────────────────────────────────────────
export function usePrices() {
  const [prices,      setPrices]      = useState(null);
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState(null);
  const [lastUpdated, setLastUpdated] = useState(null);
  const prevRef = useRef(null);

  const refresh = async () => {
    try {
      const raw = await fetchCoinGecko();

      const next = {};
      for (const [sym, d] of Object.entries(raw)) {
        const prev = prevRef.current?.[sym];
        next[sym] = {
          ...d,
          direction: prev
            ? d.usd > prev.usd ? "up" : d.usd < prev.usd ? "down" : "flat"
            : "flat",
        };
      }

      const ethChange = Math.abs(next.ETH?.change24h ?? 3);
      next._volatilityBps = Math.min(
        Math.max(Math.round((ethChange / 100) * Math.sqrt(365) * 10000), 500),
        20000
      );

      prevRef.current = next;
      setPrices(next);
      setLastUpdated(new Date());
      setError(null);
    } catch (e) {
      setError(`${e.message}`);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 30_000);
    return () => clearInterval(id);
  }, []);

  return { prices, loading, error, source: "CoinGecko", lastUpdated, refetch: refresh };
}
