/**
 * DemoMode — generates plausible fake data so the dashboard
 * looks useful even without a live chain connection.
 */
export function generateDemoData() {
  const rand = (min, max) => +(Math.random() * (max - min) + min).toFixed(4);

  return {
    insurance: {
      balance0: rand(50000, 200000).toString(),
      balance1: rand(20, 80).toString(),
      totalPaidOut0: rand(5000, 30000).toString(),
      totalPaidOut1: rand(2, 15).toString(),
      totalDeposited0: rand(100000, 500000).toString(),
      totalDeposited1: rand(40, 200).toString(),
      tvl: rand(150000, 600000).toString(),
    },
    hook: {
      baseFee: 30,
      targetVolBps: 3000,
      mevThresholdBps: 50,
      paused: false,
      pools: [
        { name: "ETH/USDC",  id: "0x88e6a0c2...", fee: rand(20, 80) | 0,  tvlUSD: rand(1e6, 5e6).toFixed(2) },
        { name: "WBTC/ETH",  id: "0x4585fe77...", fee: rand(25, 100) | 0, tvlUSD: rand(5e5, 3e6).toFixed(2) },
        { name: "LINK/ETH",  id: "0xa6cc3c25...", fee: rand(30, 120) | 0, tvlUSD: rand(2e5, 1e6).toFixed(2) },
      ],
    },
    compounder: {
      tvl: rand(5e5, 3e6).toFixed(4),
      positions: Math.floor(rand(5, 40)),
      protocolFeeBps: 200,
      keeperRewardBps: 50,
      maxTVLCap: "50000.0000",
      minDepositAmount: "100.0000",
    },
  };
}
