"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.MULTI_POSITION_ABI = exports.AUTO_RANGE_HOOK_ABI = exports.AUTO_COMPOUNDER_ABI = void 0;
// ─── AutoCompounder ABI (subset used by keeper) ───────────────────
exports.AUTO_COMPOUNDER_ABI = [
    {
        name: "compoundPosition",
        type: "function",
        stateMutability: "nonpayable",
        inputs: [
            { name: "positionId", type: "bytes32" },
            {
                name: "poolKey",
                type: "tuple",
                components: [
                    { name: "currency0", type: "address" },
                    { name: "currency1", type: "address" },
                    { name: "fee", type: "uint24" },
                    { name: "tickSpacing", type: "int24" },
                    { name: "hooks", type: "address" },
                ],
            },
            { name: "newTickLower", type: "int24" },
            { name: "newTickUpper", type: "int24" },
        ],
        outputs: [
            {
                name: "result",
                type: "tuple",
                components: [
                    { name: "newCapital0", type: "uint256" },
                    { name: "newCapital1", type: "uint256" },
                    { name: "newTickLower", type: "int24" },
                    { name: "newTickUpper", type: "int24" },
                    { name: "feesCollected0", type: "uint256" },
                    { name: "feesCollected1", type: "uint256" },
                    { name: "ilRealized0", type: "uint256" },
                    { name: "gasCostWei", type: "uint256" },
                    { name: "protocolFee0", type: "uint256" },
                    { name: "protocolFee1", type: "uint256" },
                ],
            },
        ],
    },
    {
        name: "getPosition",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "positionId", type: "bytes32" }],
        outputs: [
            {
                name: "",
                type: "tuple",
                components: [
                    { name: "owner", type: "address" },
                    { name: "poolId", type: "bytes32" },
                    { name: "tickLower", type: "int24" },
                    { name: "tickUpper", type: "int24" },
                    { name: "liquidity", type: "uint128" },
                    { name: "depositTime", type: "uint256" },
                    { name: "lastCompound", type: "uint256" },
                    { name: "compoundCount", type: "uint256" },
                    { name: "initialCapital0", type: "uint256" },
                    { name: "initialCapital1", type: "uint256" },
                    { name: "totalFees0", type: "uint256" },
                    { name: "totalFees1", type: "uint256" },
                    { name: "totalIL0", type: "uint256" },
                    { name: "riskProfile", type: "uint8" },
                    { name: "status", type: "uint8" },
                ],
            },
        ],
    },
    {
        name: "getCompoundUrgency",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "positionId", type: "bytes32" }],
        outputs: [{ name: "", type: "uint8" }],
    },
];
// ─── AutoRangeHook ABI (subset) ───────────────────────────────────
exports.AUTO_RANGE_HOOK_ABI = [
    {
        name: "getPositionsNeedingRebalance",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "poolId", type: "bytes32" }],
        outputs: [
            { name: "urgent", type: "bytes32[]" },
            { name: "urgencies", type: "uint8[]" },
        ],
    },
    {
        name: "suggestedRanges",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "posKey", type: "bytes32" }],
        outputs: [
            { name: "tickLower", type: "int24" },
            { name: "tickUpper", type: "int24" },
            { name: "confidence", type: "uint256" },
            { name: "updatedAt", type: "uint256" },
        ],
    },
];
// ─── MultiPositionStrategyHook ABI (subset) ───────────────────────
exports.MULTI_POSITION_ABI = [
    {
        name: "getStrategy",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "stratKey", type: "bytes32" }],
        outputs: [
            { name: "lp", type: "address" },
            { name: "capital0", type: "uint256" },
            { name: "capital1", type: "uint256" },
            { name: "pending", type: "bool" },
            { name: "layerALower", type: "int24" },
            { name: "layerAUpper", type: "int24" },
            { name: "layerBLower", type: "int24" },
            { name: "layerBUpper", type: "int24" },
            { name: "layerCLower", type: "int24" },
            { name: "layerCUpper", type: "int24" },
        ],
    },
    {
        name: "markStrategyExecuted",
        type: "function",
        stateMutability: "nonpayable",
        inputs: [{ name: "stratKey", type: "bytes32" }],
        outputs: [],
    },
];
