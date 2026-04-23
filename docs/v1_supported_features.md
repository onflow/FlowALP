# FlowALP v1 — Supported Features

> **Status:** Draft — items marked ⚠️ require confirmation before finalization.

---

## 1. Supported Collateral (Input Tokens)

| Token | Type | Collateral Factor | Borrow Factor |
|-------|------|:-----------------:|:-------------:|
| FLOW  | Native Flow token | 0.80 | 0.90 |
| WETH  | EVM-bridged | 0.75 | 0.85 |
| WBTC  | EVM-bridged | 0.70 | 0.80 |
| MOET  | Protocol token | ⚠️ ??? | ⚠️ ??? |

> ⚠️ **USDF** appears in fork test configurations alongside FLOW/WETH/WBTC — confirm whether it is in v1 scope.

### Mainnet Token Identifiers

| Token | Vault Type Identifier |
|-------|----------------------|
| FLOW  | `A.1654653399040a61.FlowToken.Vault` |
| WETH  | `A.1e4aa0b87d10b141.EVMVMBridgedToken_2f6f07cdcf3588944bf4c42ac74ff24bf56e7590.Vault` |
| WBTC  | `A.1e4aa0b87d10b141.EVMVMBridgedToken_717dae2baf7656be9a9b01dee31d571a9d4c9579.Vault` |
| MOET  | `A.6b00ff876c299c61.MOET.Vault` |

---

## 2. Output / Debt Token

**MOET only.** All borrowing is exclusively denominated in MOET. There is no other borrow-able asset in v1.

---

## 3. Position Limits

| Parameter | Value | Notes |
|-----------|-------|-------|
| Minimum position value | ⚠️ ??? | Set via governance (`setMinimumTokenBalancePerPosition`) |
| Maximum deposit per token | 1,000,000 (default) | Governance-configurable cap per token |
| Deposit limit fraction | 5% of capacity per deposit | Default; configurable per token |

---

## 4. Health Factors

| Parameter | Value |
|-----------|-------|
| Minimum health (liquidation threshold) | 1.10 |
| Target health (post-rebalance) | 1.30 |
| Maximum health ceiling | 1.50 |
| Liquidation target health factor | 1.05 |

---

## 5. Rebalancing

| Parameter | Value |
|-----------|-------|
| Rebalancing frequency | 10 minutes (600 seconds) |
| Rebalance trigger | Position health < target health (1.30) |
| Warmup period after unpause | 300 seconds before liquidations re-enable |
| Positions processed per async callback | 100 |

The rebalancing interval is configurable per position via `RecurringConfigImplv1`. The 10-minute interval is the intended default for `FlowALPRebalancerPaidv1`.

---

## 6. Risk & Liquidation

- Positions with health factor **< 1.10** are eligible for liquidation.
- Maximum allowed DEX-to-oracle price deviation: **300 bps (3%)**.
- Liquidation brings the position back to health factor **1.05**.

---

## 7. Protocol Fees

| Parameter | Value | Notes |
|-----------|-------|-------|
| Insurance rate | ⚠️ ??? | Governance-configurable per token |
| Stability fee rate | ⚠️ ??? | Governance-configurable per token |
| Combined constraint | `insuranceRate + stabilityFeeRate < 100%` | Enforced by contract |

---

## 8. Interest Rate Model

Two curves are supported in v1:

- **`FixedCurve`** — a flat yearly rate (e.g., 0% default for MOET).
- **`KinkCurve`** — variable rate with an optimal-utilization kink point.

Interest rate parameters are set per token by governance.

---

## Open Items

| # | Item | Owner |
|---|------|-------|
| 1 | MOET collateral factor & borrow factor for v1 | |
| 2 | Confirm USDF inclusion in v1 scope | |
| 3 | Minimum position value floor (e.g. $10 or $100 USD equivalent) | |
| 4 | Confirm 1,000,000 deposit cap is the intended v1 limit | |
| 5 | Insurance rate and stability fee rate values for each collateral | |
