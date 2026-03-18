# ADR: MOET Reserve Architecture — Pure Mint/Burn Model

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

A secondary question emerged: how should insurance fees denominated in MOET be handled, given that there is no MOET reserve vault in the pure mint/burn model?

The decision was needed to unblock PR #184 (multi-debt-type positions) and to eliminate scattered `isMOET` guard clauses throughout the protocol's token-agnostic lending logic.

### Background: Net MOET Supply Dynamics

A critical property of the pure mint/burn model is that total MOET repayment obligations will always exceed total MOET minted. Because interest accrues on borrowed MOET, borrowers owe the protocol more MOET than was originally issued. In a closed system, this would be a fatal flaw — there literally would not be enough MOET in existence for all borrowers to repay.

The system resolves this through the **redeemer contract**: a bidirectional smart contract that allows anyone to exchange $1 of stablecoins for MOET (at a small premium, e.g. 1%) or redeem MOET for stablecoins. This ensures MOET supply can always be supplemented from outside the protocol when repayment demand exceeds circulating supply. In a full wind-down scenario, the last borrowers would need to acquire MOET via the redeemer, leaving the redeemer with excess stablecoin reserves — which is the correct and expected outcome.

During the current bootstrapping phase, DEX liquidity in the MOET/stablecoin pool serves as a functional equivalent to the redeemer contract. The cost of accessing stables via the DEX (or eventually the redeemer) is precisely what determines the MOET borrow rate: the protocol charges borrowers what it costs to maintain MOET's redemption guarantee.

The redeemer contract is not yet deployed. Until it is, DEX liquidity plays this role.

---

## Competitive Benchmarks

**MakerDAO/Sky (DAI/USDS):** The canonical endogenous stablecoin. DAI is minted against collateral in CDPs and burned on repayment — a pure mint/burn model for the synthetic itself. MakerDAO does not hold DAI reserves; supply is entirely virtual and tracks outstanding debt. The Peg Stability Module (PSM) holds real stablecoins for redemption but that is a separate mechanism from core CDP mechanics. The PSM is the closest analogue to the redeemer contract described above.

**Aave GHO:** Aave's native stablecoin follows the same pattern — minted on borrow, burned on repay. No GHO vault held by the protocol. Facilitators (e.g., Aave pool, FlashMinter) are allocated mint limits; there is no concept of "spending down reserves before minting."

**Compound (USDC markets):** Compound does hold actual USDC in supply-side reserves, but USDC is not an endogenous synthetic — it is an external stablecoin deposited by third parties. Not analogous to MOET.

**Key lesson from production:** Hybrid models (draw from reserves first, mint when empty) introduce accounting complexity that has repeatedly caused subtle bugs in DeFi — reserve balance and outstanding debt can diverge, creating insolvency edge cases under stress. MakerDAO explicitly rejected reserve-backed minting for DAI for this reason. The pure mint/burn approach eliminates this entire category of invariant violation.

---

## Decision

FlowALP adopts a **pure mint/burn model** for all MOET flows through the token reserve interface.

The token reserve for MOET is implemented as an object satisfying `FungibleToken.Receiver` and `FungibleToken.Provider`, but backed by a MOET minter rather than a vault:

- **`withdraw` (any amount)** → mints new MOET and returns it to the caller.
- **`deposit` (any amount)** → burns the received MOET immediately.

This applies uniformly to both collateral operations and debt operations. The protocol does **not** distinguish between `depositCollateral` vs. `depositRepayment`, nor between `withdrawDebt` vs. `withdrawCollateral` at the reserve level — all four operations route through the same two-method interface.

**Insurance fees** are the one explicit exception: they are collected and held in a **separate, dedicated MOET vault** (not routed through the burn path). Because there is no MOET reserve vault, collecting insurance fees requires minting MOET at the moment of collection. This minting is fully algorithmic and proportional to interest accrued. The insurance fund vault is distinct from the reserve object and is never used for lending.

---

## Rationale

### Why pure mint/burn over vault-backed reserves?

Holding MOET in a reserve vault creates a persistent accounting problem: the amount of MOET in reserves can diverge from the amount of MOET that depositors are owed. Consider:

- User A deposits 100 MOET as collateral. Reserve now holds 100 MOET.
- User B borrows 100 MOET from the reserve. Reserve is now empty.
- User A repays 5 MOET of interest. Reserve now holds 5 MOET.
- User A wants to withdraw their 100 MOET collateral. Protocol can only provide 5.

Under pure mint/burn, the same sequence has no such problem:

- User A deposits 100 MOET as collateral → those 100 MOET are **burned** immediately. No reserve is held.
- User B borrows 100 MOET → 100 MOET is **minted** on demand and given to User B.
- User A repays 5 MOET of interest → those 5 MOET are **burned** immediately.
- User A wants to withdraw their 100 MOET collateral → 100 MOET is **minted** on demand and returned to User A.

At no point does the protocol need to hold a MOET inventory. Every withdrawal obligation is satisfied by minting, and every deposit reduces outstanding supply by burning. The protocol's books always balance: total MOET in circulation equals total outstanding debt, with no reserve account that can run dry.

### Why not the four-method interface?

During design, a four-method interface (`depositCollateral`, `depositRepayment`, `withdrawDebt`, `withdrawCollateral`) was considered with asymmetric MOET behaviour: collateral deposits would be vault-backed while debt repayments would be burned. This was rejected because it re-introduces the same accounting divergence — burning repayments without a corresponding deposit means accrued interest cannot be covered from reserves, requiring periodic minting anyway. The simpler two-method interface achieves the same encapsulation without the accounting complexity.

### Why hold insurance fees rather than burn them?

Insurance fees represent a buffer against bad debt. They need to remain accessible as a usable pool of capital (for selling into MOET on-market during a shortfall, or eventually backing a redemption mechanism). Burning them would destroy the insurance fund. Minting them into a segregated vault on collection is the cleanest way to build the fund under a pure mint/burn reserve model.

All protocol income should be explicit and directed to the insurance fund — there should be no implicit income or hidden value accumulation anywhere in the system. This was confirmed as the intended accounting invariant: the sum of protocol fees (insurance + stability), net credit balances, and net debit balances should equal zero. In practice, rounding may cause minor drift; this is resolved by allowing epsilon adjustments to insurance collection (±1 unit) to maintain the invariant, or via a periodic reconciliation function.

The minting of insurance fees is fully algorithmic and proportional to interest accrued, making it transparent and auditable.

This approach was reviewed and accepted as correct and workable for v1. The insurance fund mechanics — specifically how fees are collected and accumulated — may be revisited in future versions as the protocol matures and more sophisticated fund management options become available.

### MOET interest rates under low demand

A edge case raised during design: what happens if more MOET is deposited than is borrowed? In this scenario, the MOET deposit interest rate approaches zero — the protocol charges only the spread between borrow and deposit rates (approximately 1%). The borrow rate itself would also collapse, because the cost of maintaining MOET redemptions via DEX or redeemer liquidity approaches zero when there is no net demand for MOET. This scenario is theoretically stable and self-limiting, though it is expected to be rare in practice: demand to borrow MOET should consistently exceed demand to deposit it.

### Rebalancing is unaffected by the reserve model

The three contexts in which "rebalancing" applies — the AutoBalancer in Flow Yield Vaults, the ALP health-factor rebalancer, and auto-liquidation — are all unaffected by whether MOET reserves are vault-backed or mint/burn.

For ALP rebalancing specifically: when a position's health falls outside its min/max bounds, the only ALP response is to interact with the topup source or drawdown sink for that position. Each position has at most one of each, and each operates on a single asset type. This means the rebalancer is indifferent to how many collateral or debt types a position holds, and indifferent to whether MOET is handled via vault or mint/burn. The reserve model is fully encapsulated and invisible to the rebalancing logic.

---

## Risk Analysis (Four Bad Scenarios)

| Scenario | Current Exposure | Post-Decision Exposure | Mitigation |
|---|---|---|---|
| **1. Collateral price drop** | MOET debt obligations remain fixed while collateral value falls; rebalancer unwinds yield to top up. Unchanged by reserve model. | Identical — the reserve model does not affect how collateral value is tracked or how rebalancing is triggered. | Active rebalancing (TopUpSource pulls); interest rate kink curve discourages over-utilisation. |
| **2. Collateral depeg** | If MOET itself depegs on-DEX, ALP halts actions depending on MOET via `dexOracleDeviationBps` (300 bps default). | Identical — reserve model does not affect oracle deviation detection. | `dexOracleDeviationBps` circuit breaker; global pause entitlement. |
| **3. Yield token price drop** | Strategy-level risk; rebalancer may crystallise a loss if forced to sell devalued yield tokens. | Identical — not affected by MOET reserve design. | AutoBalancer harvest threshold (>105% of historical); FYV strategy diversification. |
| **4. Yield token depeg + collateral price drop (combined stress)** | Rebalancer stalls if yield token DEX price drops below redemption price; ALP may liquidate collateral. | **Marginally improved**: because MOET supply is 100% virtual, the protocol can always mint MOET to return collateral to users — there is no "reserve exhaustion" scenario where users cannot exit even under stress. | Interest rate kink model skyrockets rates at high utilisation; insurance fund (separate MOET vault) provides backstop for bad debt; active rebalancing targets HF 1.3. |

**Net assessment:** The pure mint/burn model eliminates one failure mode (reserve exhaustion under high utilisation) while introducing no new risks. The net MOET supply deficit (more owed than exists) is resolved structurally by the redeemer contract and DEX liquidity, not by the reserve model itself.

---

## Alternatives Considered

**1. Vault-backed reserves (Status: Rejected)**
Hold deposited MOET in a reserve vault; lend from it; mint only when reserves are exhausted. Rejected because interest accrual creates an accounting gap: burning repayments removes more MOET than is deposited, leaving the reserve unable to satisfy withdrawal obligations. Produces the same "bank run" risk as hybrid models, with worse transparency.

**2. Four-method interface with asymmetric MOET behaviour (Status: Rejected)**
`depositCollateral` → vault; `depositRepayment` → burn; `withdrawDebt` → mint; `withdrawCollateral` → vault. Considered as an intermediate step. Rejected upon working through the interest-accounting implications: burning repayments without vault-side deposits means the reserve cannot cover interest owed to collateral depositors, requiring periodic minting anyway. Adds complexity without eliminating the accounting gap.

**3. Hybrid model (Status: Rejected)**
Use reserves while available, mint/burn when empty. Explicitly rejected as producing a "way madness lies" class of accounting invariant violations. No production DeFi protocol uses this model for an endogenous synthetic.

**4. No change — keep scattered `isMOET` guard clauses (Status: Rejected)**
The prior implementation added MOET-specific branches throughout token-agnostic code, creating maintenance debt and surface area for bugs. The interface-encapsulated approach is strictly better.

---

## Implementation Notes

The token reserve interface should be implemented as an object satisfying both `FungibleToken.Receiver` and `FungibleToken.Provider`:

- **For non-MOET tokens**: backed by a `Vault` of the corresponding token type. `withdraw`/`deposit` pass through directly to the underlying vault.
- **For MOET**: backed by a MOET minter resource. `withdraw` calls `minter.mintTokens(amount)`. `deposit` calls the MOET contract's `burnCallback()`.

This encapsulation means the rest of the ALP codebase (position management, rebalancing, liquidation) interacts with reserves through a single interface, without any `isMOET` conditional logic. MOET's special behaviour is entirely contained within the reserve object.

**Insurance fee collection** remains a separate path: fees are minted via the minter and deposited into a dedicated `insuranceFund` vault. This vault is access-controlled and its MOET is never routed through the lending reserve. During insurance collection, an epsilon adjustment (±1 unit) may be applied to maintain the protocol-wide accounting invariant that net credits + net debits + fees = 0.

**Position close** is handled via `closePosition()`, which accepts an array of sources corresponding to each open debt type. The method withdraws up to debt + epsilon from each source, converting all balances from debit to credit, then returns all collateral and residual amounts as vaults. This design ensures position closure is atomic and does not require the caller to know exact debt balances (which may drift due to per-second interest compounding).

**The redeemer contract** (not yet deployed) will provide a permanent external source of MOET for borrowers who cannot source enough MOET from the open market to repay their debt. Until then, the MOET/stablecoin DEX pool serves this function. The borrow rate charged to MOET borrowers should reflect the cost of maintaining this redemption capacity.

---

## User Impact

- **Borrowers**: No change to borrowing mechanics, rates, or health factor calculations. The reserve model is internal to the protocol.
- **MOET depositors (as collateral)**: Their deposited MOET is burned immediately; on withdrawal, equivalent MOET is minted. Net economic effect is identical to vault-backed storage. Users do not observe any difference.
- **Lenders / yield depositors**: Interest earned continues to accrue via the scaled balance system. Insurance fee deduction from lender yield is unchanged (default 0.1%). If MOET deposit demand were to exceed borrow demand, the deposit rate on MOET would approach zero — users are not harmed but earn less.
- **Liquidators**: No impact. Liquidation bonus (5%) and mechanics are unchanged.
- **Peak Money users**: Transparent. The position balance formula (`CT + (YV − CD) × CP`) is unaffected. The reserve model does not alter how position value is computed or displayed.

---

## Communication Angle

FlowALP's MOET reserve design follows the same battle-tested model used by MakerDAO's DAI and Aave's GHO: synthetic supply is entirely virtual, minted against collateral and burned on repayment, with no reserve exhaustion risk. The redeemer contract (and DEX liquidity in the interim) ensures the system can always reach zero cleanly, while the insurance fund accumulates a permanent MOET buffer against bad debt — built algorithmically from borrower fees, not governance discretion.
