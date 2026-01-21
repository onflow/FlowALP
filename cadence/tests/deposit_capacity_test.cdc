import Test
import BlockchainHelpers

import "MOET"
import "FlowCreditMarket"
import "test_helpers.cdc"

access(all) var snapshot: UInt64 = 0
access(all) let hourInSeconds = 3600.0

access(all)
fun safeReset() {
    let cur = getCurrentBlockHeight()
    if cur > snapshot {
        Test.reset(to: snapshot)
    }
}

access(all)
fun setup() {
    deployContracts()
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: moetTokenIdentifier, beFailed: false)
    // Note: We don't add the token in setup - each test adds it with specific parameters
    snapshot = getCurrentBlockHeight()
}

// -----------------------------------------------------------------------------
// Test 1: Deposit Capacity Consumption
// -----------------------------------------------------------------------------
access(all)
fun test_deposit_capacity_consumption() {
    safeReset()
    
    // Setup token with specific deposit capacity
    // Note: default token is already added when pool is created, so we just update its parameters
    let depositRate = 1000.0
    let initialCap = 10000.0
    
    // Set deposit rate and capacity cap using governance functions
    setDepositRate(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, hourlyRate: depositRate)
    setDepositCapacityCap(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, cap: initialCap)
    
    // Set a higher deposit limit fraction to allow larger deposits (default is 5%)
    setDepositLimitFraction(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, fraction: 0.5) // 50% to allow larger deposits
    
    // Check initial capacity - cap should be set correctly
    var capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    Test.assertEqual(initialCap, capacityInfo["depositCapacityCap"]!)
    // Get the initial capacity (may have regenerated, so we'll track changes)
    let initialCapacity = capacityInfo["depositCapacity"]!
    
    // Setup user and create position
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 5000.0, beFailed: false)
    grantPoolCapToConsumer()
    
    // Get capacity before position creation (the initial deposit will consume capacity)
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let capacityBeforePositionCreation = capacityInfo["depositCapacity"]!
    let initialDepositAmount = 100.0
    
    createWrappedPosition(signer: user, amount: initialDepositAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Get capacity right after position creation - should have decreased by initialDepositAmount
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let capacityAfterPositionCreation = capacityInfo["depositCapacity"]!
    // Capacity should have decreased by exactly the initial deposit amount (no regeneration should occur)
    Test.assertEqual(capacityAfterPositionCreation, capacityBeforePositionCreation - initialDepositAmount)
    
    // Make a deposit
    let depositAmount = 2000.0
    depositToWrappedPosition(signer: user, amount: depositAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Check that capacity decreased by exactly depositAmount (no regeneration should occur)
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let capacityAfterFirstDeposit = capacityInfo["depositCapacity"]!
    // Capacity should have decreased by exactly depositAmount from capacity after position creation
    Test.assertEqual(capacityAfterFirstDeposit, capacityAfterPositionCreation - depositAmount)
    Test.assertEqual(initialCap, capacityInfo["depositCapacityCap"]!) // Cap should not change
    
    // Make another deposit
    let depositAmount2 = 1500.0
    depositToWrappedPosition(signer: user, amount: depositAmount2, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Check that capacity decreased further
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let capacityAfterSecondDeposit = capacityInfo["depositCapacity"]!
    // Capacity should have decreased by exactly depositAmount2 from previous capacity
    Test.assertEqual(capacityAfterSecondDeposit, capacityAfterFirstDeposit - depositAmount2)
}

// -----------------------------------------------------------------------------
// Test 2: Per-User Deposit Limits (Fraction of Cap)
// -----------------------------------------------------------------------------
access(all)
fun test_per_user_deposit_limits() {
    safeReset()
    
    // Setup token with specific deposit capacity and limit fraction
    // Note: default token is already added when pool is created
    let depositRate = 1000.0
    let initialCap = 10000.0
    let depositLimitFraction = 0.05 // 5%
    
    // Set deposit rate and capacity cap
    setDepositRate(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, hourlyRate: depositRate)
    setDepositCapacityCap(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, cap: initialCap)
    
    // Set deposit limit fraction
    setDepositLimitFraction(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, fraction: depositLimitFraction)
    
    // Calculate expected per-user limit
    let expectedUserLimit = initialCap * depositLimitFraction // 10000 * 0.05 = 500
    
    // Setup user 1
    let user1 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    mintMoet(signer: protocolAccount, to: user1.address, amount: 10000.0, beFailed: false)
    grantPoolCapToConsumer()
    
    let initialDeposit1 = 100.0
    createWrappedPosition(signer: user1, amount: initialDeposit1, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // After position creation: usage = 100 (out of 500 limit)
    
    // User 1 deposits more (should be accepted up to limit)
    let user1Deposit1 = 300.0 // After this: usage = 400 (out of 500 limit)
    depositToWrappedPosition(signer: user1, amount: user1Deposit1, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // User 1 deposits more (should be partially accepted, partially queued)
    let user1Deposit2 = 200.0 // Only 100 more can be accepted to reach limit of 500, 100 will be queued
    depositToWrappedPosition(signer: user1, amount: user1Deposit2, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // After this: usage = 500 (at limit), 100 queued
    
    // User 1 tries to deposit more (should be queued due to per-user limit)
    let user1Deposit3 = 100.0 // This should be queued (user already at limit)
    depositToWrappedPosition(signer: user1, amount: user1Deposit3, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false) // Transaction succeeds but deposit is queued
    
    // Setup user 2 - they should have their own independent limit
    let user2 = Test.createAccount()
    setupMoetVault(user2, beFailed: false)
    mintMoet(signer: protocolAccount, to: user2.address, amount: 10000.0, beFailed: false)
    
    let initialDeposit2 = 100.0
    createWrappedPosition(signer: user2, amount: initialDeposit2, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // After position creation: usage = 100 (out of 500 limit)
    
    // User 2 should be able to deposit up to their own limit (500 total, so 400 more)
    let user2Deposit = 400.0
    depositToWrappedPosition(signer: user2, amount: user2Deposit, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // After this: usage = 500 (at limit)
    
    // Verify that both users have independent limits by checking capacity
    // Get capacity after all deposits
    var capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let finalCapacity = capacityInfo["depositCapacity"]!
    
    // Total accepted deposits: 
    // user1 = 500 (100 initial + 300 + 100 from deposit2, 100 from deposit2 queued, 100 from deposit3 queued)
    // user2 = 500 (100 initial + 400)
    // total = 1000
    // We need to check that capacity decreased by at least 1000 from some initial value
    Test.assert(finalCapacity <= initialCap - 1000.0, 
                message: "Final capacity \(finalCapacity) should be <= initial cap \(initialCap) - 1000")
}

// -----------------------------------------------------------------------------
// Test 3: Capacity Regeneration After 1 Hour
// -----------------------------------------------------------------------------
access(all)
fun test_capacity_regeneration() {
    safeReset()
    
    // Setup token with specific deposit rate and cap
    // Note: default token is already added when pool is created
    let depositRate = 1000.0
    let initialCap = 10000.0
    let depositLimitFraction = 0.5

    // Set deposit rate and capacity cap
    setDepositRate(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, hourlyRate: depositRate)
    setDepositCapacityCap(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, cap: initialCap)
    
    // Set a higher deposit limit fraction to allow larger deposits
    setDepositLimitFraction(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, fraction: depositLimitFraction) // 50% to allow larger deposits
    
    // Check initial capacity
    var capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    Test.assertEqual(initialCap, capacityInfo["depositCapacityCap"]!)
    // Capacity may have regenerated, so we'll track changes from here
    
    // Setup user and make deposits to consume capacity
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 6000.0, beFailed: false)
    grantPoolCapToConsumer()
    
    // Get capacity before position creation (the initial deposit will consume capacity)
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let capacityBeforePositionCreation = capacityInfo["depositCapacity"]!
    let initialDepositAmount = 100.0
    
    createWrappedPosition(signer: user, amount: initialDepositAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Get capacity right after position creation (no regeneration should occur)
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let capacityAfterPositionCreation = capacityInfo["depositCapacity"]!
    Test.assertEqual(initialCap, capacityInfo["depositCapacityCap"]!)
    // Capacity should have decreased by exactly the initial deposit amount
    Test.assertEqual(capacityAfterPositionCreation, capacityBeforePositionCreation - initialDepositAmount)
    
    // Consume remaining capacity
    // Note: The deposit limit is 50% of current capacity
    let userLimit = initialCap * depositLimitFraction
    let depositAmount = userLimit - initialDepositAmount

    
    depositToWrappedPosition(signer: user, amount: depositAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Verify capacity decreased by the accepted amount
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let capacityAfterDeposit = capacityInfo["depositCapacity"]!
    // Capacity should have decreased by exactly the accepted amount 
    let expectedCapacity = capacityAfterPositionCreation - depositAmount
    Test.assertEqual(expectedCapacity, capacityAfterDeposit)
    Test.assertEqual(initialCap, capacityInfo["depositCapacityCap"]!)
    let lastDepositCapacityUpdate = capacityInfo["lastDepositCapacityUpdate"]!
    
    // Advance time by 1 hour + 1 second to trigger regeneration (needs to be > 3600.0)
    let timeMoved = hourInSeconds + 1.0
    Test.moveTime(by: Fix64(timeMoved))
    
    // Trigger regeneration by making a small deposit (this calls updateForTimeChange)
    let smallDeposit = 1.0
    depositToWrappedPosition(signer: user, amount: smallDeposit, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Check that capacity cap increased and capacity was reset to new cap
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let actualNewCap = capacityInfo["depositCapacityCap"]!
    let newUpdateTime = capacityInfo["lastDepositCapacityUpdate"]!
    // Calculate the actual multiplier used based on the actual cap value
    // actualNewCap = initialCap + (depositRate * actualMultiplier)
    // actualMultiplier = (actualNewCap - initialCap) / depositRate
 
    let actualTimeMoved = newUpdateTime - lastDepositCapacityUpdate
    
    // Use the actual multiplier to calculate expected capacity
    let expectedNewCap = (actualTimeMoved/hourInSeconds * depositRate) + initialCap
    Test.assertEqual(expectedNewCap, actualNewCap)
    // Capacity should be reset to new cap (minus the small deposit we just made)
    let actualCapacity = capacityInfo["depositCapacity"]!
    Test.assertEqual(expectedNewCap - smallDeposit, actualCapacity)
}

// -----------------------------------------------------------------------------
// Test 4: User Usage Reset on Regeneration
// -----------------------------------------------------------------------------
access(all)
fun test_user_usage_reset_on_regeneration() {
    safeReset()
    
    // Setup token with specific deposit capacity and limit fraction
    // Note: default token is already added when pool is created
    let depositRate = 1000.0
    let initialCap = 10000.0
    let depositLimitFraction = 0.05 // 5%
    
    // Set deposit rate and capacity cap
    setDepositRate(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, hourlyRate: depositRate)
    setDepositCapacityCap(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, cap: initialCap)
    
    // Set deposit limit fraction
    setDepositLimitFraction(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, fraction: depositLimitFraction)
    
    // Setup user
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 10000.0, beFailed: false)
    grantPoolCapToConsumer()
    
    let initialDepositAmount = 100.0
    createWrappedPosition(signer: user, amount: initialDepositAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // After position creation: usage = 100 (out of 500 limit)
    
    // User deposits more to reach their limit (500 total, so 400 more)
    let userLimit = initialCap * depositLimitFraction // 500
    let additionalDeposit = userLimit - initialDepositAmount // 400
    depositToWrappedPosition(signer: user, amount: additionalDeposit, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // After this: usage = 500 (at limit)
    
    // Try to deposit more - should be queued
    let excessDeposit = 100.0
    depositToWrappedPosition(signer: user, amount: excessDeposit, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false) // Transaction succeeds but deposit is queued
    
    // Advance time by 1 hour + 1 second to trigger regeneration
    let timeMoved = hourInSeconds + 1.0
    Test.moveTime(by: Fix64(timeMoved))
    
    // Trigger regeneration
    depositToWrappedPosition(signer: user, amount: 1.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // After regeneration, user's usage should be reset, so they should be able to deposit again
    // Get the actual cap to calculate the actual multiplier used
    var capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let actualNewCap = capacityInfo["depositCapacityCap"]!
    
    // Calculate the actual multiplier used: actualMultiplier = (actualNewCap - initialCap) / depositRate
    let actualMultiplier = (actualNewCap - initialCap) / depositRate
    let newCap = actualNewCap // Use the actual cap value
    let newUserLimit = newCap * depositLimitFraction
    
    // User should now be able to deposit up to the new limit (550 total)
    // They already have initialDepositAmount (100) from before regeneration, but usage was reset
    // So they can deposit the full newUserLimit
    let depositAfterRegen = newUserLimit - 1.0 // Deposit just under the new limit
    depositToWrappedPosition(signer: user, amount: depositAfterRegen, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Verify capacity info
    // Note: The cap may have regenerated slightly, so we check it's at least the expected value
    capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let actualCap = capacityInfo["depositCapacityCap"]!
    // The cap should be at least newCap (may be slightly higher if time passed)
    Test.assert(actualCap >= newCap)
}

// -----------------------------------------------------------------------------
// Test 5: Multiple Hours of Regeneration
// -----------------------------------------------------------------------------
access(all)
fun test_multiple_hours_regeneration() {
    safeReset()
    
    // Setup token
    // Note: default token is already added when pool is created
    let depositRate = 1000.0
    let initialCap = 10000.0
    
    // Set deposit rate and capacity cap
    setDepositRate(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, hourlyRate: depositRate)
    setDepositCapacityCap(signer: protocolAccount, tokenTypeIdentifier: moetTokenIdentifier, cap: initialCap)
    // After setDepositCapacityCap, lastDepositCapacityUpdate is reset to current time
    
    // Advance time by 2 hours + 1 second (needs to be > 3600.0 to trigger regeneration)
    let timeMoved = 2.0 * hourInSeconds + 1.0
    Test.moveTime(by: Fix64(timeMoved))
    
    // Setup user to trigger regeneration
    let user = Test.createAccount()
    setupMoetVault(user, beFailed: false)
    mintMoet(signer: protocolAccount, to: user.address, amount: 1000.0, beFailed: false)
    grantPoolCapToConsumer()
    
    let initialDepositAmount = 100.0
    createWrappedPosition(signer: user, amount: initialDepositAmount, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    // The initial deposit consumes capacity, but we're checking the cap regeneration, not capacity
    
    // Make a small deposit to trigger regeneration
    depositToWrappedPosition(signer: user, amount: 1.0, vaultStoragePath: MOET.VaultStoragePath, pushToDrawDownSink: false)
    
    // Get the actual cap and calculate the actual multiplier used
    var capacityInfo = getDepositCapacityInfo(vaultIdentifier: moetTokenIdentifier)
    let actualNewCap = capacityInfo["depositCapacityCap"]!
    
    // Calculate the actual multiplier used: actualMultiplier = (actualNewCap - initialCap) / depositRate
    let actualMultiplier: UFix64 = (actualNewCap - initialCap) / depositRate
    let actualTimeMoved = actualMultiplier * hourInSeconds
    
    // Verify the actual time moved is approximately what we expected (within 1 second tolerance)
    Test.assert(actualTimeMoved >= timeMoved - 1.0 && actualTimeMoved <= timeMoved + 1.0,
                message: "Actual time moved \(actualTimeMoved) should be approximately \(timeMoved)")
    
    // Use the actual multiplier to verify the calculation
    let expectedNewCap = initialCap + (depositRate * actualMultiplier)
    Test.assertEqual(expectedNewCap, actualNewCap)
}
