# Manual Liquidation Before Automated Liquidation

**Status**: Accepted
**Date**: 2026-03-18
**Authors**: Jordan Schalm
**Component**: ALP

### References
- [Slack discussion in Flow Foundation](https://flow-foundation.slack.com/archives/C08QF29F7TK/p1766009587712529)

## Context

The protocol needs a liquidation mechanism to handle unhealthy positions. Two broad approaches exist: automated liquidation (typically involving on-chain arbitrage bots and AMM integration) and manual liquidation (a human-triggered process operated by a known party). Initially, all FlowALP users are expected to be clients of FYV or Peak Money, both of which should ensure a top-up source is available. Combined with auto-rebalancing, this means unhealthy positions are expected to be rare.

## Decision

Implement manual liquidation first, deferring automated liquidation to a later phase. The Flow Foundation will operate the only manual liquidator initially, triggered by a human operator rather than an arbitrage bot. Metrics will be put in place to alert when a position becomes unhealthy and eligible for liquidation.

## Rationale

1. **Simplicity.** Manual liquidation is significantly simpler to implement than an automated system, reducing development time and the surface area for bugs in a critical protocol function.
2. **No AMM dependency.** Automated liquidation typically requires integration with an AMM for token swaps. Manual liquidation uses an AMM for price reference, but can function (with a mock or minor implementation changes) without an AMM.
3. **Low expected frequency.** Auto-rebalancing and the fact that all users will be clients of FYV or Peak Money (both providing top-up sources) make unhealthy positions unlikely. Building a sophisticated automated system for an event that may rarely or never occur is premature.
4. **Acceptable operational risk.** Having the Flow Foundation operate the sole liquidator manually is an acceptable trade-off at this stage given the low expected volume.

## Alternatives Considered

### Automated Liquidation
FlowALP uses scheduled transactions to periodically check health and perform liquidations against an AMM.
- Requires AMM integration for token swaps, adding a dependency that doesn't yet need to exist.
- Significantly more complex to implement and audit.
- The expected frequency of liquidations does not justify the engineering investment at this stage.

We intend to implement this as a supplement to manual liquidation in the future, and a design doc is available [here](https://www.notion.so/flowfoundation/Liquidation-Design-2f61aee123248084818fd8843974f6fa)

## Implementation Notes

- **Metrics and alerting:** Implement monitoring to detect when positions approach unhealthy thresholds, so the operator is alerted when liquidation becomes necessary.
- **Documented runbook:** Create a documented process for the Flow Foundation operator to follow when performing a manual liquidation.
- **Single operator:** The Flow Foundation will be the sole liquidator initially. Permissionless liquidation is allowed, but we don't depend on it.
- **Future path:** Automated liquidation should be added later.

## User Impact

- **End users (FYV / Peak Money clients):** No negative impact expected. Positions are protected by auto-rebalancing and top-up sources. If a liquidation is needed, though, it doesn't matter to users how it happens.
