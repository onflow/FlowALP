# MOET Reserve Architecture — Pure Mint/Burn Model

**Status**: Accepted
**Date**: 2026-03-05
**Authors**: Jordan Schalm, Dieter Shirley (review), Alexandr Ni (implementation)
**Component**: ALP / MOET

---

## Context

FlowALP treats MOET differently from every other token in the system: it is the endogenous synthetic stablecoin minted against collateral. This raises a structural question about how the protocol should manage MOET internally when it is used as collateral or borrowed as debt.

Three candidate designs were on the table:

1. **Vault-backed reserves** — hold actual MOET in a reserve pool, lending from it as needed.
2. **Hybrid** — lend from reserves while reserves exist, mint otherwise; return repayments to reserves if space, burn otherwise.
3. **Pure mint/burn** — treat all MOET supply inside the protocol as virtual; mint on every withdrawal (debt issuance or collateral return), burn on every deposit (debt repayment or collateral deposit).

A secondary question: how should insurance fees denominated in MOET be handled, given that there is no MOET reserve vault in the pure mint/burn model?

The decision was needed to unblock PR #184 (multi-debt-type positions) and to eliminate scattered `isMOET` guard clauses throughout the protocol's token-agnostic lending logic.

### Background: Net MOET Supply Dynamics

Because interest accrues on borrowed MOET, total repayment obligations will always exceed total MOET minted — borrowers owe more than was issued. The system resolves this through the **redeemer contract** (and DEX liquidity in the interim): anyone can exchange stablecoins for MOET, ensuring supply can always be supplemented when repayment demand exceeds circulating supply.

---

## Competitive Benchmarks

**MakerDAO/Sky (DAI)** and **Aave GHO** both follow the pure mint/burn model: synthetic supply is entirely virtual, minted on borrow, burned on repay, with no reserve vault held by the protocol.

**Key lesson from production:** Hybrid models introduce accounting complexity where reserve balance and outstanding debt can diverge, creating insolvency edge cases. MakerDAO explicitly rejected reserve-backed minting for DAI for this reason.

---

## Decision

FlowALP adopts a **pure mint/burn model** for all MOET flows through the token reserve interface.

The token reserve for MOET is implemented as an object satisfying `FungibleToken.Receiver` and `FungibleToken.Provider`, but backed by a MOET minter rather than a vault:

- **`withdraw` (any amount)** → mints new MOET and returns it to the caller.
- **`deposit` (any amount)** → burns the received MOET immediately.

This applies uniformly to both collateral and debt operations — all four paths (`depositCollateral`, `depositRepayment`, `withdrawDebt`, `withdrawCollateral`) route through the same two-method interface.

**Insurance fees** are the one explicit exception: collected and held in a **separate, dedicated MOET vault** (minted at collection time, never routed through the burn path, never used for lending).

---

## Rationale

### Why pure mint/burn over vault-backed reserves?

Vault-backed reserves create an accounting gap that grows with interest accrual:

- User A deposits 100 MOET as collateral. Reserve holds 100 MOET.
- User B borrows 100 MOET. Reserve is empty.
- User A repays 5 MOET interest. Reserve holds 5 MOET.
- User A withdraws collateral. Protocol can only provide 5.

Under pure mint/burn, every deposit is burned and every withdrawal is minted on demand — the protocol never needs to hold inventory and the books always balance.

### Why not the four-method interface?

A four-method interface with asymmetric MOET behaviour (vault for collateral, burn for repayments) was rejected because it re-introduces the same accounting divergence — burning repayments without vault-side deposits means accrued interest can never be covered from reserves.

### Why hold insurance fees rather than burn them?

Insurance fees are a buffer against bad debt and must remain accessible as deployable capital. Burning them would destroy the insurance fund. Minting into a segregated vault on collection is the cleanest approach under a pure mint/burn reserve model.

---

## Alternatives Considered

**1. Vault-backed reserves** — Rejected. Interest accrual creates an accounting gap; the reserve cannot satisfy withdrawal obligations over time.

**2. Four-method interface with asymmetric MOET behaviour** — Rejected. Burning repayments without vault deposits still requires periodic minting; adds complexity without eliminating the gap.

**3. Hybrid model** — Rejected. Produces accounting invariant violations where reserve balance and outstanding debt diverge. No production DeFi protocol uses this for an endogenous synthetic.


---

## Implementation Notes

The token reserve interface satisfies both `FungibleToken.Receiver` and `FungibleToken.Provider`:

- **Non-MOET tokens**: backed by a `Vault`; `withdraw`/`deposit` pass through directly.
- **MOET**: backed by a minter resource. `withdraw` calls `minter.mintTokens(amount)`; `deposit` calls `burnCallback()`.

Insurance fees are minted separately and deposited into a dedicated `insuranceFund` vault. An epsilon adjustment (±1 unit) may be applied during collection to maintain the accounting invariant that net credits + net debits + fees = 0.

---

## User Impact

- **Borrowers / liquidators**: No change to mechanics, rates, or health factor calculations. The reserve model is internal.
- **MOET depositors**: Deposited MOET is burned immediately; on withdrawal, equivalent MOET is minted. Net economic effect is identical to vault-backed storage — users observe no difference.
