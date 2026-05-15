import { useState, useCallback } from "react";
import { BrowserProvider, JsonRpcProvider } from "ethers";

const ANVIL_URL = "http://127.0.0.1:8545";

export function useProvider() {
  const [provider, setProvider] = useState(null);
  const [account, setAccount]   = useState(null);
  const [chainId, setChainId]   = useState(null);
  const [error, setError]       = useState(null);
  const [connecting, setConnecting] = useState(false);

  const connectMetaMask = useCallback(async () => {
    setError(null);
    setConnecting(true);
    try {
      if (!window.ethereum) throw new Error("MetaMask not found");
      const p = new BrowserProvider(window.ethereum);
      const accounts = await p.send("eth_requestAccounts", []);
      const net = await p.getNetwork();
      setProvider(p);
      setAccount(accounts[0]);
      setChainId(Number(net.chainId));
    } catch (e) {
      setError(e.message);
    } finally {
      setConnecting(false);
    }
  }, []);

  const connectAnvil = useCallback(async () => {
    setError(null);
    setConnecting(true);
    try {
      const p = new JsonRpcProvider(ANVIL_URL);
      const net = await p.getNetwork();
      const accounts = await p.listAccounts();
      setProvider(p);
      setAccount(accounts[0]?.address ?? "0xAnvil");
      setChainId(Number(net.chainId));
    } catch (e) {
      setError(`Cannot connect to Anvil at ${ANVIL_URL}: ${e.message}`);
    } finally {
      setConnecting(false);
    }
  }, []);

  const disconnect = useCallback(() => {
    setProvider(null);
    setAccount(null);
    setChainId(null);
    setError(null);
  }, []);

  return { provider, account, chainId, error, connecting, connectMetaMask, connectAnvil, disconnect };
}
