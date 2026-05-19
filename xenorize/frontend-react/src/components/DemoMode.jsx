/**
 * DemoMode — generates plausible simulated on-chain state.
 * When real prices are available, uses them as anchors so TVL / balances
 * are in the right ballpark relative to current ETH price.
 */
export function generateDemoData(prices = null) {
  const rand = (min, max) => +(Math.random() * (max - min) + min).toFixed(4);

  const ethPrice  = prices?.ETH?.usd  ?? 2500;
  const wbtcPrice = prices?.WBTC?.usd ?? 60000;
  const linkPrice = prices?.LINK?.usd ?? 15;

  const ethTVL  = rand(800, 1200);
  const wbtcTVL = rand(5, 15);
  const linkTVL = rand(10000, 50000);

  const tvlUSD_eth  = (ethTVL  * ethPrice).toFixed(2);
  const tvlUSD_wbtc = (wbtcTVL * wbtcPrice).toFixed(2);
  const tvlUSD_link = (linkTVL * linkPrice).toFixed(2);

  // ─── ERC-4626 Insurance Vault ─────────────────────────────────
  const protocolFeeIncome = rand(80_000, 300_000);  // cumulative protocol fees routed in
  const stakedByUsers     = rand(50_000, 200_000);  // user ERC-4626 deposits
  const totalILPaidOut    = rand(20_000, Math.min(protocolFeeIncome * 0.6, 150_000));
  const totalAssets       = protocolFeeIncome + stakedByUsers - totalILPaidOut;
  const totalShares       = totalAssets * rand(0.9, 1.1); // ~1:1 initially
  const sharePrice        = totalShares > 0 ? totalAssets / totalShares : 1;
  const managedTVL        = ethTVL * ethPrice + wbtcTVL * wbtcPrice;
  const fundHealthBps     = managedTVL > 0
    ? Math.min(10000, Math.round((totalAssets / managedTVL) * 10000))
    : 10000;

  // ─── IL Shield Hook ────────────────────────────────────────────
  const activeSnapshots   = Math.floor(rand(8, 40));
  const totalClaimsPaid   = Math.floor(rand(5, 25));
  const totalILDetected   = totalILPaidOut / rand(0.3, 0.55);  // IL detected > compensated
  const totalCompensated  = totalILPaidOut;
  const avgLoyaltyDays    = Math.floor(rand(20, 75));
  const compensationRatePct = totalILDetected > 0
    ? (totalCompensated / totalILDetected) * 100
    : 0;

  // 7-day IL history
  const today = new Date();
  const ilHistory = Array.from({ length: 7 }, (_, i) => {
    const d = new Date(today);
    d.setDate(d.getDate() - (6 - i));
    const ilDay    = rand(500, 8000);
    const compDay  = ilDay * rand(0.3, 0.5);
    return {
      day:          d.toLocaleDateString("en-US", { weekday: "short" }),
      ilDetected:   +ilDay.toFixed(2),
      compensated:  +compDay.toFixed(2),
    };
  });

  // Recent claims
  const pools = ["ETH/USDC", "WBTC/ETH", "LINK/ETH"];
  const recentClaims = Array.from({ length: Math.min(totalClaimsPaid, 5) }, (_, i) => {
    const days = Math.floor(rand(1, 90));
    const ilAmt = rand(200, 5000);
    return {
      lp:           `0x${Math.floor(Math.random() * 0xffff).toString(16).padStart(4, "0")}…`,
      pool:         pools[i % pools.length],
      ilUSD:        ilAmt.toFixed(2),
      compensation: (ilAmt * Math.min(1, days / 90) * 0.5).toFixed(2),
      loyaltyDays:  days,
    };
  });

  // Loyalty distribution: Bronze (<30d), Silver (30-90d), Gold (>90d)
  const totalPos = activeSnapshots;
  const goldCount   = Math.floor(totalPos * rand(0.1, 0.3));
  const silverCount = Math.floor(totalPos * rand(0.3, 0.5));
  const bronzeCount = totalPos - goldCount - silverCount;
  const loyaltyDist = [
    { tier: "Bronze\n<30d",  count: Math.max(0, bronzeCount) },
    { tier: "Silver\n30-90d", count: Math.max(0, silverCount) },
    { tier: "Gold\n>90d",    count: Math.max(0, goldCount)   },
  ];

  // ─── Dynamic fee ──────────────────────────────────────────────
  const ethChange     = Math.abs(prices?.ETH?.change24h  ?? 3);
  const wbtcChangePct = Math.abs(prices?.WBTC?.change24h ?? 2.5);
  const linkChangePct = Math.abs(prices?.LINK?.change24h ?? 4);
  const dynamicBps    = Math.round(30 + ethChange * 8);

  return {
    insurance: {
      // ERC-4626 vault fields
      totalAssets:    totalAssets.toFixed(4),
      sharePrice:     sharePrice.toFixed(6),
      totalShares:    totalShares.toFixed(4),
      totalFeeIncome: protocolFeeIncome.toFixed(4),
      totalPaidOut:   totalILPaidOut.toFixed(4),
      stakedByUsers:  stakedByUsers.toFixed(4),
      fundHealthBps:  fundHealthBps.toString(),
    },

    ilShield: {
      activeSnapshots,
      totalClaimsPaid,
      totalILDetected:   totalILDetected.toFixed(4),
      totalCompensated:  totalCompensated.toFixed(4),
      avgLoyaltyDays,
      compensationRatePct: compensationRatePct.toFixed(2),
      ilHistory,
      recentClaims,
      loyaltyDist,
    },

    hook: {
      baseFee:         30,
      targetVolBps:    3000,
      mevThresholdBps: 50,
      paused:          false,
      pools: [
        {
          name:      "ETH/USDC",
          id:        "0x88e6a0c2…",
          fee:       Math.min(Math.round(dynamicBps), 10000),
          tvlUSD:    tvlUSD_eth,
          priceUSD:  ethPrice,
          change24h: prices?.ETH?.change24h ?? 0,
        },
        {
          name:      "WBTC/ETH",
          id:        "0x4585fe77…",
          fee:       Math.min(Math.round(30 + wbtcChangePct * 7), 10000),
          tvlUSD:    tvlUSD_wbtc,
          priceUSD:  wbtcPrice,
          change24h: prices?.WBTC?.change24h ?? 0,
        },
        {
          name:      "LINK/ETH",
          id:        "0xa6cc3c25…",
          fee:       Math.min(Math.round(30 + linkChangePct * 9), 10000),
          tvlUSD:    tvlUSD_link,
          priceUSD:  linkPrice,
          change24h: prices?.LINK?.change24h ?? 0,
        },
      ],
    },

    compounder: {
      tvl:              (ethTVL * ethPrice + wbtcTVL * wbtcPrice).toFixed(4),
      positions:        Math.floor(rand(5, 40)),
      protocolFeeBps:   200,
      keeperRewardBps:  50,
      maxTVLCap:        "50000.0000",
      minDepositAmount: "100.0000",
    },
  };
}
