import React from "react";

export default function Header({ account, chainId, connecting, onMetaMask, onAnvil, onDisconnect }) {
  const shortAddr = account
    ? `${account.slice(0, 6)}...${account.slice(-4)}`
    : null;

  const chainName = chainId === 1 ? "Mainnet"
    : chainId === 11155111 ? "Sepolia"
    : chainId === 31337 ? "Anvil (local)"
    : chainId ? `Chain ${chainId}`
    : null;

  return (
    <header className="header">
      <div className="header-left">
        <span className="logo">⚡</span>
        <div>
          <h1>Xenorize AMM</h1>
          <p className="subtitle">Uniswap V4 · Dynamic Fees · IL Insurance</p>
        </div>
      </div>

      <div className="header-right">
        {account ? (
          <div className="wallet-info">
            <span className="chain-badge">{chainName}</span>
            <span className="address">{shortAddr}</span>
            <button className="btn btn-ghost" onClick={onDisconnect}>Disconnect</button>
          </div>
        ) : (
          <div className="wallet-buttons">
            <button className="btn btn-primary" onClick={onMetaMask} disabled={connecting}>
              {connecting ? "Connecting…" : "Connect MetaMask"}
            </button>
            <button className="btn btn-secondary" onClick={onAnvil} disabled={connecting}>
              Anvil Local
            </button>
          </div>
        )}
      </div>
    </header>
  );
}
