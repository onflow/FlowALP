# CRITICAL SECURITY ISSUE: Position Ownership Not Enforced

## Issue
The `repayAndClosePosition()` method added in PR #16 does NOT check position ownership. This means:
- **Anyone can close anyone else's position**
- Malicious actors could repay someone's debt and steal their collateral
- This is a critical vulnerability that must be fixed before production

## Current State
```cadence
access(all) fun repayAndClosePosition(
    pid: UInt64,
    repaymentVault: @{FungibleToken.Vault},
    collateralReceivers: {Type: Capability<&{FungibleToken.Receiver}>}
): @{Type: {FungibleToken.Vault}}
```

The method only checks:
- Position ID exists
- Repayment is in MOET
- But does NOT verify the caller owns the position

## Root Cause
The TidalProtocol design doesn't track position ownership at the contract level:
- Positions are stored in a mapping by ID
- The Position struct (held by users) contains the ID
- But there's no owner field in InternalPosition

## Proposed Solutions

### Option 1: Add Owner Tracking (Recommended)
Add owner field to InternalPosition and check it:
```cadence
access(all) resource InternalPosition {
    access(all) let owner: Address  // Add this
    // ... existing fields
}

// In repayAndClosePosition:
pre {
    position.owner == callerAddress: "Only position owner can close"
}
```

### Option 2: Require Position Capability
Make the method require the Position struct as proof:
```cadence
access(all) fun repayAndClosePosition(
    position: &Position,  // Require this as proof of ownership
    repaymentVault: @{FungibleToken.Vault},
    // ...
)
```

### Option 3: Move to Position Struct
Add the method to Position struct instead of Pool:
```cadence
access(all) struct Position {
    access(all) fun repayAndClose(
        repaymentVault: @{FungibleToken.Vault},
        // ...
    )
}
```

## Temporary Mitigation
Until fixed, the transaction should be modified to only work through the PositionWrapper, ensuring only the wrapper holder can execute it.

## Impact
- **Severity**: CRITICAL
- **Exploitability**: HIGH (anyone can call)
- **Impact**: Total loss of collateral for victims

This MUST be fixed before any mainnet deployment. 