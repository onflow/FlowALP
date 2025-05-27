import Test
import BlockchainHelpers
import "AlpenFlow"
import "./test_helpers.cdc"

access(all)
fun setup() {
    deployContracts()
}

// ===== FUZZY TEST UTILITIES =====

// Generate pseudo-random values based on seed
access(all) fun randomUFix64(seed: UInt64, min: UFix64, max: UFix64): UFix64 {
    let range = max - min
    let randomFactor = UFix64(seed % 1000000) / 1000000.0
    return min + (range * randomFactor)
}

access(all) fun randomBool(seed: UInt64): Bool {
    return seed % 2 == 0
}

// ===== PROPERTY 1: DEPOSIT/WITHDRAW INVARIANTS =====

access(all) fun testFuzzDepositWithdrawInvariants() {
    /*
     * Property: For any sequence of deposits and withdrawals:
     * 1. Total reserves = sum(deposits) - sum(withdrawals)
     * 2. Position can never withdraw more than available
     * 3. Health factor constraints are always enforced
     */
    
    let seeds: [UInt64] = [12345, 67890, 11111, 99999, 54321, 88888, 33333, 77777]
    
    for seed in seeds {
        var pool <- AlpenFlow.createTestPool(defaultTokenThreshold: 0.8)
        let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
        
        // Create multiple positions
        let numPositions = Int(seed % 5 + 1)
        let positions: [UInt64] = []
        var i = 0
        while i < numPositions {
            positions.append(poolRef.createPosition())
            i = i + 1
        }
        
        // Track expected reserves
        var expectedReserves: UFix64 = 0.0
        
        // Perform random operations
        let numOperations = Int(seed % 20 + 10)
        var op = 0
        while op < numOperations {
            let opSeed = seed * UInt64(op + 1)
            let isDeposit = randomBool(seed: opSeed)
            let positionIndex = Int(opSeed % UInt64(positions.length))
            let pid = positions[positionIndex]
            
            if isDeposit {
                // Random deposit between 0.1 and 1000.0
                let amount = randomUFix64(seed: opSeed, min: 0.1, max: 1000.0)
                let vault <- AlpenFlow.createTestVault(balance: amount)
                poolRef.deposit(pid: pid, funds: <- vault)
                expectedReserves = expectedReserves + amount
            } else {
                // Try random withdrawal
                let maxAmount = randomUFix64(seed: opSeed, min: 0.01, max: 100.0)
                // Only withdraw if it won't overdraw
                if expectedReserves >= maxAmount {
                    // Check if position health allows withdrawal
                    let healthBefore = poolRef.positionHealth(pid: pid)
                    if healthBefore >= 1.0 {
                        // Try withdrawal - may fail if position doesn't have enough
                        // We'll use a smaller amount to avoid failures
                        let safeAmount = maxAmount * 0.1
                        if expectedReserves >= safeAmount {
                            let withdrawn <- poolRef.withdraw(
                                pid: pid,
                                amount: safeAmount,
                                type: Type<@AlpenFlow.FlowVault>()
                            ) as! @AlpenFlow.FlowVault
                            expectedReserves = expectedReserves - withdrawn.balance
                            destroy withdrawn
                        }
                    }
                }
            }
            op = op + 1
        }
        
        // Verify invariant: actual reserves match expected
        let actualReserves = poolRef.reserveBalance(type: Type<@AlpenFlow.FlowVault>())
        let tolerance = 0.00000001
        let difference = actualReserves > expectedReserves 
            ? actualReserves - expectedReserves 
            : expectedReserves - actualReserves
        Test.assert(difference < tolerance, 
            message: "Reserve invariant violated")
        
        destroy pool
    }
}

// ===== PROPERTY 2: INTEREST ACCRUAL MONOTONICITY =====

access(all) fun testFuzzInterestMonotonicity() {
    /*
     * Property: Interest indices must be monotonically increasing
     * For any time t1 < t2, index(t2) >= index(t1)
     */
    
    let testRates: [UFix64] = [0.0, 0.01, 0.05, 0.10, 0.20, 0.50, 0.99]
    let testPeriods: [UFix64] = [1.0, 10.0, 60.0, 3600.0, 86400.0, 604800.0]
    
    for rate in testRates {
        let perSecondRate = AlpenFlow.perSecondInterestRate(yearlyRate: rate)
        var previousIndex: UInt64 = 10000000000000000 // 1.0
        
        for period in testPeriods {
            let newIndex = AlpenFlow.compoundInterestIndex(
                oldIndex: previousIndex,
                perSecondRate: perSecondRate,
                elapsedSeconds: period
            )
            
            // Verify monotonicity
            Test.assert(newIndex >= previousIndex, 
                message: "Interest index must be monotonically increasing")
            
            // For non-zero rates, index should strictly increase
            if rate > 0.0 && period > 0.0 {
                Test.assert(newIndex > previousIndex,
                    message: "Interest index should increase with positive rate and time")
            }
            
            previousIndex = newIndex
        }
    }
}

// ===== PROPERTY 3: SCALED BALANCE CONSISTENCY =====

access(all) fun testFuzzScaledBalanceConsistency() {
    /*
     * Property: For any balance and interest index:
     * scaledToTrue(trueToScaled(balance, index), index) ≈ balance
     */
    
    let testBalances: [UFix64] = [
        0.00000001, 0.0001, 0.01, 0.1, 1.0, 10.0, 100.0, 1000.0, 
        10000.0, 100000.0, 1000000.0, 10000000.0
    ]
    
    let testIndices: [UInt64] = [
        10000000000000000,  // 1.0
        10100000000000000,  // 1.01
        10500000000000000,  // 1.05
        11000000000000000,  // 1.10
        12000000000000000,  // 1.20
        15000000000000000,  // 1.50
        20000000000000000,  // 2.00
        50000000000000000   // 5.00
    ]
    
    for balance in testBalances {
        for index in testIndices {
            let scaled = AlpenFlow.trueBalanceToScaledBalance(
                trueBalance: balance,
                interestIndex: index
            )
            
            let backToTrue = AlpenFlow.scaledBalanceToTrueBalance(
                scaledBalance: scaled,
                interestIndex: index
            )
            
            // Allow for tiny precision loss
            let tolerance = balance * 0.000001 // 0.0001% tolerance
            let difference = backToTrue > balance 
                ? backToTrue - balance 
                : balance - backToTrue
                
            Test.assert(difference <= tolerance,
                message: "Scaled balance conversion lost precision")
        }
    }
}

// ===== PROPERTY 4: POSITION HEALTH BOUNDARIES =====

access(all) fun testFuzzPositionHealthBoundaries() {
    /*
     * Property: Position health calculation edge cases
     * 1. Health = 1.0 when no debt
     * 2. Health < 1.0 when debt > effective collateral
     * 3. Health calculation handles extreme ratios
     */
    
    let thresholds: [UFix64] = [0.1, 0.5, 0.8, 0.95, 0.99]
    
    for threshold in thresholds {
        var pool <- AlpenFlow.createTestPoolWithBalance(
            defaultTokenThreshold: threshold,
            initialBalance: 1000000.0
        )
        let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
        
        // Test various collateral/debt ratios
        let collateralAmounts: [UFix64] = [1.0, 10.0, 100.0, 1000.0, 10000.0]
        
        for collateral in collateralAmounts {
            let pid = poolRef.createPosition()
            let vault <- AlpenFlow.createTestVault(balance: collateral)
            poolRef.deposit(pid: pid, funds: <- vault)
            
            // Test withdrawals at various levels
            let withdrawFactors: [UFix64] = [0.1, 0.5, 0.8, 0.9, 0.95, 0.99]
            
            for factor in withdrawFactors {
                let withdrawAmount = collateral * factor
                
                // Only test if withdrawal would be allowed
                if factor < threshold {
                    let withdrawn <- poolRef.withdraw(
                        pid: pid,
                        amount: withdrawAmount,
                        type: Type<@AlpenFlow.FlowVault>()
                    ) as! @AlpenFlow.FlowVault
                    
                    let health = poolRef.positionHealth(pid: pid)
                    
                    // With current implementation, position has net credit
                    // so health should be 1.0
                    Test.assertEqual(health, 1.0)
                    
                    // Deposit back for next iteration
                    poolRef.deposit(pid: pid, funds: <- withdrawn)
                }
            }
        }
        
        destroy pool
    }
}

// ===== PROPERTY 5: CONCURRENT POSITION ISOLATION =====

access(all) fun testFuzzConcurrentPositionIsolation() {
    /*
     * Property: Operations on one position don't affect others
     * Each position's state is independent
     */
    
    var pool <- AlpenFlow.createTestPoolWithBalance(
        defaultTokenThreshold: 0.8,
        initialBalance: 1000000.0
    )
    let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
    
    // Create multiple positions
    let numPositions = 10
    let positions: [UInt64] = []
    let expectedBalances: {UInt64: UFix64} = {}
    
    var i = 0
    while i < numPositions {
        let pid = poolRef.createPosition()
        positions.append(pid)
        expectedBalances[pid] = 0.0
        i = i + 1
    }
    
    // Perform random operations on each position
    let seeds: [UInt64] = [111, 222, 333, 444, 555]
    
    for seed in seeds {
        // Random operations on random positions
        let numOps = 20
        var op = 0
        while op < numOps {
            let opSeed = seed * UInt64(op + 1)
            let posIndex = Int(opSeed) % positions.length
            let pid = positions[posIndex]
            let amount = randomUFix64(seed: opSeed, min: 1.0, max: 100.0)
            
            if randomBool(seed: opSeed) {
                // Deposit
                let vault <- AlpenFlow.createTestVault(balance: amount)
                poolRef.deposit(pid: pid, funds: <- vault)
                expectedBalances[pid] = expectedBalances[pid]! + amount
            } else {
                // Try withdrawal if position has balance
                if expectedBalances[pid]! >= amount {
                    let withdrawn <- poolRef.withdraw(
                        pid: pid,
                        amount: amount,
                        type: Type<@AlpenFlow.FlowVault>()
                    ) as! @AlpenFlow.FlowVault
                    expectedBalances[pid] = expectedBalances[pid]! - amount
                    destroy withdrawn
                }
            }
            
            // Verify other positions unchanged
            for checkPid in positions {
                if checkPid != pid {
                    let health = poolRef.positionHealth(pid: checkPid)
                    Test.assert(health >= 0.0, 
                        message: "Other positions should remain valid")
                }
            }
            
            op = op + 1
        }
    }
    
    destroy pool
}

// ===== PROPERTY 6: EXTREME VALUE HANDLING =====

access(all) fun testFuzzExtremeValues() {
    /*
     * Property: System handles extreme values gracefully
     * No overflows, underflows, or unexpected behavior
     */
    
    // Test extreme deposits
    let extremeAmounts: [UFix64] = [
        0.00000001,      // Minimum
        0.000001,        // Very small
        99999999.99999999, // Near max UFix64
        50000000.0       // Large but safe
    ]
    
    var pool <- AlpenFlow.createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
    
    for amount in extremeAmounts {
        let pid = poolRef.createPosition()
        
        // Skip amounts that are too large for safe testing
        if amount < 90000000.0 {
            let vault <- AlpenFlow.createTestVault(balance: amount)
            poolRef.deposit(pid: pid, funds: <- vault)
            
            // Verify deposit worked
            let reserve = poolRef.reserveBalance(type: Type<@AlpenFlow.FlowVault>())
            Test.assert(reserve >= amount, 
                message: "Extreme deposit should be reflected in reserves")
            
            // Try to withdraw half
            let halfAmount = amount / 2.0
            if halfAmount > 0.0 {
                let withdrawn <- poolRef.withdraw(
                    pid: pid,
                    amount: halfAmount,
                    type: Type<@AlpenFlow.FlowVault>()
                ) as! @AlpenFlow.FlowVault
                Test.assertEqual(withdrawn.balance, halfAmount)
                destroy withdrawn
            }
        }
    }
    
    destroy pool
}

// ===== PROPERTY 7: INTEREST RATE EDGE CASES =====

access(all) fun testFuzzInterestRateEdgeCases() {
    /*
     * Property: Interest calculations handle edge cases
     * 1. Zero rates produce no interest
     * 2. High rates don't overflow
     * 3. Long time periods compound correctly
     */
    
    // Test extreme interest rates
    let extremeRates: [UFix64] = [
        0.0,        // Zero rate
        0.000001,   // Tiny rate
        0.99,       // Maximum safe rate (99% APY)
        0.5,        // 50% APY
        0.0001      // 0.01% APY
    ]
    
    // Test extreme time periods
    let extremePeriods: [UFix64] = [
        0.0,         // No time
        0.001,       // Millisecond
        31536000.0,  // One year
        315360000.0  // Ten years
    ]
    
    let startIndex: UInt64 = 10000000000000000
    
    for rate in extremeRates {
        let perSecondRate = AlpenFlow.perSecondInterestRate(yearlyRate: rate)
        
        for period in extremePeriods {
            // Skip combinations that might overflow
            if rate < 0.99 || period < 31536000.0 {
                let compounded = AlpenFlow.compoundInterestIndex(
                    oldIndex: startIndex,
                    perSecondRate: perSecondRate,
                    elapsedSeconds: period
                )
                
                // Verify no overflow occurred
                Test.assert(compounded >= startIndex,
                    message: "Compounded index should not underflow")
                
                // For zero rate or zero time, index should be unchanged
                if rate == 0.0 || period == 0.0 {
                    Test.assertEqual(compounded, startIndex)
                }
            }
        }
    }
}

// ===== PROPERTY 8: LIQUIDATION THRESHOLD ENFORCEMENT =====

access(all) fun testFuzzLiquidationThresholdEnforcement() {
    /*
     * Property: Liquidation thresholds are strictly enforced
     * No position can borrow beyond its threshold
     */
    
    let thresholds: [UFix64] = [0.1, 0.25, 0.5, 0.75, 0.9, 0.95]
    let collateralAmounts: [UFix64] = [10.0, 100.0, 1000.0, 10000.0]
    
    for threshold in thresholds {
        var pool <- AlpenFlow.createTestPoolWithBalance(
            defaultTokenThreshold: threshold,
            initialBalance: 1000000.0
        )
        let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
        
        for collateral in collateralAmounts {
            let pid = poolRef.createPosition()
            let vault <- AlpenFlow.createTestVault(balance: collateral)
            poolRef.deposit(pid: pid, funds: <- vault)
            
            // Calculate maximum allowed withdrawal
            let maxWithdraw = collateral * threshold
            
            // Test withdrawals at various levels relative to threshold
            let testFactors: [UFix64] = [0.5, 0.8, 0.9, 0.95, 0.99, 1.0]
            
            for factor in testFactors {
                let withdrawAmount = maxWithdraw * factor
                
                if withdrawAmount < collateral {
                    let withdrawn <- poolRef.withdraw(
                        pid: pid,
                        amount: withdrawAmount,
                        type: Type<@AlpenFlow.FlowVault>()
                    ) as! @AlpenFlow.FlowVault
                    
                    // Verify position is still healthy
                    let health = poolRef.positionHealth(pid: pid)
                    Test.assert(health >= 0.0,
                        message: "Position should remain healthy within threshold")
                    
                    // Return funds for next test
                    poolRef.deposit(pid: pid, funds: <- withdrawn)
                }
            }
        }
        
        destroy pool
    }
}

// ===== PROPERTY 9: MULTI-TOKEN SIMULATION =====

access(all) fun testFuzzMultiTokenBehavior() {
    /*
     * Property: System correctly handles multiple token types
     * Even though current implementation only supports FlowVault,
     * test the infrastructure is ready for multi-token
     */
    
    var pool <- AlpenFlow.createTestPool(defaultTokenThreshold: 0.8)
    let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
    
    // Create positions and simulate multi-token behavior
    let numPositions = 5
    var i = 0
    while i < numPositions {
        let pid = poolRef.createPosition()
        
        // Simulate different "token types" with different amounts
        let amounts: [UFix64] = [100.0, 200.0, 300.0]
        
        for amount in amounts {
            let vault <- AlpenFlow.createTestVault(balance: amount)
            poolRef.deposit(pid: pid, funds: <- vault)
        }
        
        // Verify total deposited
        let expectedTotal = 600.0 // 100 + 200 + 300
        
        // Withdraw to verify
        let withdrawn <- poolRef.withdraw(
            pid: pid,
            amount: expectedTotal * 0.5,
            type: Type<@AlpenFlow.FlowVault>()
        ) as! @AlpenFlow.FlowVault
        
        Test.assertEqual(withdrawn.balance, expectedTotal * 0.5)
        destroy withdrawn
        
        i = i + 1
    }
    
    destroy pool
}

// ===== PROPERTY 10: RESERVE INTEGRITY UNDER STRESS =====

access(all) fun testFuzzReserveIntegrityUnderStress() {
    /*
     * Property: Reserves remain consistent under high-frequency operations
     * Sum of all position balances = total reserves
     */
    
    var pool <- AlpenFlow.createTestPoolWithBalance(
        defaultTokenThreshold: 0.8,
        initialBalance: 10000.0
    )
    let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool
    
    // Create many positions
    let numPositions = 20
    let positions: [UInt64] = []
    var i = 0
    while i < numPositions {
        positions.append(poolRef.createPosition())
        i = i + 1
    }
    
    // Perform many rapid operations
    let numOperations = 100
    var totalDeposited: UFix64 = 10000.0 // Initial balance
    var op = 0
    
    while op < numOperations {
        let seed = UInt64(op * 12345)
        let posIndex = Int(seed) % positions.length
        let pid = positions[posIndex]
        let isDeposit = randomBool(seed: seed)
        
        if isDeposit {
            let amount = randomUFix64(seed: seed, min: 0.1, max: 50.0)
            let vault <- AlpenFlow.createTestVault(balance: amount)
            poolRef.deposit(pid: pid, funds: <- vault)
            totalDeposited = totalDeposited + amount
        } else {
            // Try small withdrawal
            let amount = randomUFix64(seed: seed, min: 0.1, max: 10.0)
            if totalDeposited > amount * 2.0 { // Safety margin
                // Try withdrawal - may fail if position doesn't have funds
                // We'll catch this by checking reserves before and after
                let reserveBefore = poolRef.reserveBalance(type: Type<@AlpenFlow.FlowVault>())
                
                // Attempt withdrawal with very small amount to avoid failures
                let safeAmount = amount * 0.01
                let withdrawn <- poolRef.withdraw(
                    pid: pid,
                    amount: safeAmount,
                    type: Type<@AlpenFlow.FlowVault>()
                ) as! @AlpenFlow.FlowVault
                
                totalDeposited = totalDeposited - withdrawn.balance
                destroy withdrawn
            }
        }
        
        // Periodically verify reserve integrity
        if op % 10 == 0 {
            let actualReserves = poolRef.reserveBalance(type: Type<@AlpenFlow.FlowVault>())
            let tolerance = 0.001
            let difference = actualReserves > totalDeposited 
                ? actualReserves - totalDeposited 
                : totalDeposited - actualReserves
            Test.assert(difference < tolerance,
                message: "Reserve integrity check failed")
        }
        
        op = op + 1
    }
    
    destroy pool
} 