📘 Multi-DEX Liquidity Migration Trap

A Drosera mainnet trap that detects suspicious liquidity migration for a token across multiple DEX pools (Uniswap V2, Uniswap V3, etc).
This trap helps protocol teams monitor and react to liquidity manipulations, rug-pull setups, or MEV-based liquidity attacks in real time.

🔍 What This Trap Detects

This trap identifies a dangerous pattern:

🔽 Sudden liquidity drop in the primary pool

(e.g., Uniswap V3 WETH/USDC)

AND

⚠️ No corresponding increase in liquidity on other pools

(e.g., Uniswap V2 / SushiSwap / other Uniswap V3 pools)

This behavior is typical when:

Liquidity is silently pulled out

Liquidity is moved to a private or malicious pool

A price manipulation attack is being prepared

An MEV-driven liquidity snipe is happening

A stealth rug is being set up

🧠 How It Works

Every Drosera cycle, the trap:

Reads liquidity from each configured pool

For Uniswap V2: uses getReserves()

For Uniswap V3: uses liquidity()

Builds a snapshot of:

block number

timestamp

pool list

liquidity values

Compares the most recent two snapshots.

Computes:

primary pool drop percentage

other pools liquidity increase percentage

compensation ratio
(did liquidity migrate, or vanish?)

Fires when:

primary liquidity drops ≥ threshold (default: 40%)

AND other pools fail to compensate (< 50%)

AND total liquidity was above a safety threshold

AND enough blocks passed (confirm window)

When triggered, the trap sends a payload to your response contract, which emits a clean event for off-chain monitoring.

🛡 Motivation

Liquidity migration attacks are common precursors to:

Price manipulation

MEV extraction

Front-run / back-run opportunities

“Liquidity vanish” rugs

Draining of LP positions

Oracle manipulation setups

Most protocols don’t monitor cross-DEX liquidity movements.

This trap does — continuously, autonomously, on-chain.
