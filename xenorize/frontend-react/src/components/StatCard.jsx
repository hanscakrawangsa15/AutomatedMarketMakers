import React from "react";

export default function StatCard({ title, value, sub, accent, icon }) {
  return (
    <div className={`stat-card ${accent ? "accent-" + accent : ""}`}>
      <div className="stat-icon">{icon}</div>
      <div className="stat-body">
        <p className="stat-title">{title}</p>
        <p className="stat-value">{value}</p>
        {sub && <p className="stat-sub">{sub}</p>}
      </div>
    </div>
  );
}
