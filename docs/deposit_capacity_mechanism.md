# Deposit Capacity Mechanism

This document describes the deposit capacity limiting system in the FlowALPv1 contract, including how deposit rates, capacity caps, and per-user limits work together to control deposit throughput.

## Overview

The deposit capacity system implements a multi-layered rate limiting mechanism to:
1. Prevent sudden large deposits from overwhelming the protocol
2. Ensure fair distribution of deposit capacity across users
3. Allow gradual capacity growth over time
4. Enforce per-user deposit limits to prevent single-user monopolization

## Components

### 1. `depositRate`

**Type**: `UFix64`  
**Location**: `TokenState` struct  
**Purpose**: The flat amount added to `depositCapacityCap` approximately once per hour.

**Behavior**:
- `depositRate` is a per-hour rate and will be multiplied by the amount of time passed
- It is added to `depositCapacityCap` when capacity regenerates
- Regeneration occurs approximately once per hour (when `dt > 3600.0` seconds)
- The regeneration check happens in `regenerateDepositCapacity()` which is called via `updateForTimeChange()`

**Example**:
- If `depositRate = 1000.0` and `depositCapacityCap = 10000.0`
- After 1 hour: `depositCapacityCap` becomes `11000.0`
- After another hour: `depositCapacityCap` becomes `12000.0`

**Initialization**:
- Set when a token type is added via `addSupportedToken()`
- Can be updated via governance function `setDepositRate()`

### 2. `depositCapacityCap`

**Type**: `UFix64`  
**Location**: `TokenState` struct  
**Purpose**: The upper bound on total deposits for a token type, limiting how much `depositCapacity` can reach.

**Behavior**:
- Represents the maximum available deposit capacity for a token type
- Starts at the initial value provided when the token is added
- Increases by `depositRate` approximately once per hour when `regenerateDepositCapacity()` is called
- When the cap increases, `depositCapacity` is set to the new cap value
- Used to calculate per-user deposit limits

**Relationship with `depositCapacity`**:
- `depositCapacity` is the current available capacity (consumed by deposits)
- `depositCapacityCap` is the maximum capacity limit
- When capacity regenerates, `depositCapacity` is set to `depositCapacityCap`
- `depositCapacity` decreases as deposits are made (via `consumeDepositCapacity()`)

**Example**:
```
Initial state:
  depositCapacityCap = 10000.0
  depositCapacity = 10000.0

After deposits totaling 3000.0:
  depositCapacityCap = 10000.0
  depositCapacity = 7000.0

After 1 hour regeneration (depositRate = 1000.0):
  depositCapacityCap = 11000.0
  depositCapacity = 11000.0  (reset to new cap)
```

**Initialization**:
- Set when a token type is added via `addSupportedToken()`
- Can be updated via governance function `setDepositCapacityCap()`

### 3. Per-User Deposit Limits

**Calculation**: `depositLimitFraction * depositCapacityCap`  
**Location**: Calculated on-the-fly via `getUserDepositLimitCap()` in `TokenState`  
**Purpose**: Limits how much a single user can deposit for a token type before capacity regenerates.

**Behavior**:
- Each user (position) has a limit calculated as: `depositLimitFraction * depositCapacityCap`
- Default `depositLimitFraction = 0.05` (5%)
- Usage is tracked per user per token type in `TokenState.depositUsage` mapping
- When a user makes a deposit, their usage is incremented by the accepted amount
- If a deposit would exceed the user's remaining limit, the excess is queued
- When capacity regenerates (cap increases), all user usage is reset to 0

**Example**:
```
Token state:
  depositCapacityCap = 10000.0
  depositLimitFraction = 0.05
  User limit = 10000.0 * 0.05 = 500.0

User A deposits:
  Deposit 1: 300.0 → accepted, usage = 300.0, remaining = 200.0
  Deposit 2: 200.0 → accepted, usage = 500.0, remaining = 0.0
  Deposit 3: 100.0 → 0.0 accepted (queued), usage = 500.0

After 1 hour regeneration (cap increases to 11000.0):
  User limit = 11000.0 * 0.05 = 550.0
  User A usage reset to 0.0
  User A can now deposit up to 550.0
```

**Usage Tracking**:
- Stored in `TokenState.depositUsage: {UInt64: UFix64}`
- Maps position ID → total usage amount for that token type
- Reset to empty dictionary `{}` when capacity regenerates

## Deposit Flow

When a user attempts to deposit:

1. **Per-Deposit Limit Check** (prevents single large deposits):
   - Calculate: `depositLimit = depositCapacity * depositLimitFraction`
   - If deposit amount > `depositLimit`, queue the excess
   - This ensures no single deposit can monopolize available capacity

2. **Per-User Limit Check** (prevents user monopolization):
   - Calculate: `userDepositLimitCap = depositCapacityCap * depositLimitFraction`
   - Get user's current usage: `tokenState.depositUsage[pid] ?? 0.0`
   - Calculate remaining: `remainingUserLimit = userDepositLimitCap - currentUsage`
   - If deposit amount > `remainingUserLimit`, queue the excess
   - This ensures fair distribution across users

3. **Capacity Consumption**:
   - Accepted deposit amount consumes from `depositCapacity`
   - User's usage is incremented in `depositUsage[pid]`

4. **Queue Processing**:
   - Queued deposits are processed asynchronously via `asyncUpdatePosition()`
   - They will be checked against limits again when processed

## Capacity Regeneration

**Trigger**: Approximately once per hour (when `dt > 3600.0` seconds)

**Process**:
1. Calculate time elapsed since last update
2. If > 1 hour:
   - Add `depositRate` to `depositCapacityCap`
   - Set `depositCapacity` to new `depositCapacityCap`
   - Reset all user usage: `depositUsage = {}`
   - Update timestamp

**When It Happens**:
- Automatically when `updateForTimeChange()` is called (via `_borrowUpdatedTokenState()`)
- Can be manually triggered for all tokens via `regenerateAllDepositCapacities()`

**Effect**:
- All users get a fresh allocation based on the new, higher cap
- Previously queued deposits may now be processable if limits increased

## Key Differences

### `depositCapacity` vs `depositCapacityCap`

- **`depositCapacity`**: Current available capacity (decreases with deposits, resets to cap on regeneration)
- **`depositCapacityCap`**: Maximum capacity limit (increases with regeneration, used for per-user limit calculation)

### Per-Deposit Limit vs Per-User Limit

- **Per-Deposit Limit**: `depositCapacity * depositLimitFraction`
  - Based on current available capacity
  - Prevents single large deposits
  - Changes as capacity is consumed
  
- **Per-User Limit**: `depositCapacityCap * depositLimitFraction`
  - Based on maximum capacity cap
  - Prevents user monopolization
  - Only changes when cap regenerates
  - Resets when capacity regenerates

## Configuration

All parameters can be configured per token type:

- **`depositRate`**: Set via `addSupportedToken()` or `setDepositRate()`
- **`depositCapacityCap`**: Set via `addSupportedToken()` or `setDepositCapacityCap()`
- **`depositLimitFraction`**: Set via `setDepositLimitFraction()` (default: 0.05 = 5%)

## Example Scenario

```
Initial Setup:
  Token: FLOW
  depositRate: 1000.0
  depositCapacityCap: 10000.0
  depositLimitFraction: 0.05
  depositCapacity: 10000.0

Per-user limit: 10000.0 * 0.05 = 500.0
Per-deposit limit: 10000.0 * 0.05 = 500.0

User A deposits 300.0:
  ✅ Accepted
  depositCapacity: 9700.0
  User A usage: 300.0
  Remaining user limit: 200.0

User B deposits 600.0:
  ✅ 500.0 accepted (per-deposit limit)
  ⏳ 100.0 queued
  depositCapacity: 9200.0
  User B usage: 500.0
  Remaining user limit: 0.0

User B tries to deposit 50.0:
  ⏳ 50.0 queued (exceeds per-user limit)
  depositCapacity: 9200.0 (unchanged)
  User B usage: 500.0 (unchanged)

After 1 hour (regeneration):
  depositCapacityCap: 11000.0 (+1000.0)
  depositCapacity: 11000.0 (reset to cap)
  All user usage reset: {}
  
  New per-user limit: 11000.0 * 0.05 = 550.0
  New per-deposit limit: 11000.0 * 0.05 = 550.0

User B's queued 50.0 can now be processed:
  ✅ 50.0 accepted
  depositCapacity: 10950.0
  User B usage: 50.0
  Remaining user limit: 500.0
```

## Summary

The deposit capacity system provides:
- **Time-based growth**: Capacity increases gradually via `depositRate`
- **Fair distribution**: Per-user limits prevent monopolization
- **Rate limiting**: Per-deposit limits prevent single large deposits
- **Automatic reset**: User limits reset when capacity regenerates
- **Per-token control**: Each token type has independent capacity management

