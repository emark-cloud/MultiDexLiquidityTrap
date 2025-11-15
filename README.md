# MultiDexLiquidityTrap (Production-Ready)

This trap detects liquidity migration across multiple pools on Uniswap V2, Uniswap V3, Sushi, Balancer, etc.

### Key Features
- Uses the same Drosera interface pattern as `HighBalanceDropTrap`
- `collect()` returns a deterministic per-block liquidity snapshot
- `shouldRespond(bytes[] data)` expects `[newest, previous]` like your existing traps
- Multi-block confirmation using `confirmBlocks`
- Primary-pool drop detection + cross-DEX compensation logic
- Hardened with error-handled external calls
- Fully unit-tested

### Foundry Commands

