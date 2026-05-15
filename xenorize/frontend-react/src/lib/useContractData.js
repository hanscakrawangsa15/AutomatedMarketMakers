import { useState, useEffect, useCallback } from "react";
import { Contract, formatUnits } from "ethers";
import {
  ADDRESSES, INSURANCE_FUND_ABI, FEE_HOOK_ABI, ORACLE_ABI,
  AUTO_COMPOUNDER_ABI, DEMO_POOLS,
} from "./contracts.js";

const fmt18 = (v) => parseFloat(formatUnits(v, 18)).toFixed(4);
const fmtBps = (v) => `${(Number(v) / 100).toFixed(2)}%`;

export function useContractData(provider) {
  const [data, setData]       = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError]     = useState(null);

  const refresh = useCallback(async () => {
    if (!provider) return;
    setLoading(true);
    setError(null);
    try {
      const fund     = new Contract(ADDRESSES.insuranceFund,  INSURANCE_FUND_ABI,   provider);
      const hook     = new Contract(ADDRESSES.dynamicFeeHook, FEE_HOOK_ABI,         provider);
      const compounder = new Contract(ADDRESSES.autoCompounder, AUTO_COMPOUNDER_ABI, provider);

      // InsuranceFund
      const [bal0, bal1, paid0, paid1, dep0, dep1, tvlFund] = await Promise.all([
        fund.fundBalance0().catch(() => 0n),
        fund.fundBalance1().catch(() => 0n),
        fund.totalPaidOut0().catch(() => 0n),
        fund.totalPaidOut1().catch(() => 0n),
        fund.totalDeposited0().catch(() => 0n),
        fund.totalDeposited1().catch(() => 0n),
        fund.totalTVL().catch(() => 0n),
      ]);

      // DynamicFeeHook
      const [baseFee, targetVol, mevThreshold, hookPaused] = await Promise.all([
        hook.baseFee().catch(() => 30),
        hook.targetVolBps().catch(() => 3000n),
        hook.mevThresholdBps().catch(() => 50n),
        hook.paused().catch(() => false),
      ]);

      // Pool fees
      const poolFees = await Promise.all(
        DEMO_POOLS.map(async (p) => {
          const fee = await hook.getCurrentFee(p.id).catch(() => 0);
          const poolTvl = await hook.poolTVLUSD(p.id).catch(() => 0n);
          return { ...p, fee: Number(fee), tvlUSD: fmt18(poolTvl) };
        })
      );

      // AutoCompounder
      const [tvlComp, positions, protocolFee, keeperReward, maxTVL, minDeposit] = await Promise.all([
        compounder.totalTVL().catch(() => 0n),
        compounder.totalPositions().catch(() => 0n),
        compounder.protocolFeeBps().catch(() => 200n),
        compounder.keeperRewardBps().catch(() => 50n),
        compounder.maxTVLCap().catch(() => 0n),
        compounder.minDepositAmount().catch(() => 0n),
      ]);

      setData({
        insurance: {
          balance0: fmt18(bal0),
          balance1: fmt18(bal1),
          totalPaidOut0: fmt18(paid0),
          totalPaidOut1: fmt18(paid1),
          totalDeposited0: fmt18(dep0),
          totalDeposited1: fmt18(dep1),
          tvl: fmt18(tvlFund),
        },
        hook: {
          baseFee: Number(baseFee),
          targetVolBps: Number(targetVol),
          mevThresholdBps: Number(mevThreshold),
          paused: hookPaused,
          pools: poolFees,
        },
        compounder: {
          tvl: fmt18(tvlComp),
          positions: Number(positions),
          protocolFeeBps: Number(protocolFee),
          keeperRewardBps: Number(keeperReward),
          maxTVLCap: fmt18(maxTVL),
          minDepositAmount: fmt18(minDeposit),
        },
      });
    } catch (e) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, [provider]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 15_000);
    return () => clearInterval(id);
  }, [refresh]);

  return { data, loading, error, refresh };
}
