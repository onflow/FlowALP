import Test
import AlpenFlow from 0xf8d6e0586b0a20c7

/*
 * TROUBLESHOOTING NOTES FOR FLOW ENGINEERS:
 * 
 * Issue: "failed to load contract: f8d6e0586b0a20c7.AlpenFlow" at line 16
 * 
 * Relevant debugging information:
 * 1. The contract is deployed to the emulator account (0xf8d6e0586b0a20c7)
 * 2. Simple tests like cadence/tests/simple_test.cdc that just import the contract PASS
 * 3. Tests that access type information (cadence/tests/access_test.cdc) also PASS
 * 4. Tests that call straightforward non-resource functions (cadence/tests/function_test.cdc) PASS
 * 5. But any test that tries to use resource-related functionality (createTestPool, createTestVault) FAILS
 *    with "failed to load contract" error
 * 
 * Attempted solutions:
 * 1. Changed all contract utility functions from access(self) to access(all)
 * 2. Fixed createTestPoolWithBalance to use AlpenFlow. instead of self.
 * 3. Restarted the emulator and redeployed the contract multiple times
 * 4. Updated flow.json to add an explicit emulator alias for the contract
 * 
 * Current hypothesis: There may be an issue with how the test runner is resolving
 * resource-related functionality in the contract, possibly related to authorization
 * or how resources are handled in the test environment.
 */

access(all)
fun testDepositWithdrawSymmetry() {
    /* 
     * Test A-1: Deposit → Withdraw symmetry
     * 
     * This test verifies that depositing funds into a position and then
     * immediately withdrawing the same amount returns the expected funds,
     * leaves reserves unchanged, and maintains a health factor of 1.0.
     */
    
    // 1. Create a fresh Pool with default token threshold 1.0
    let defaultThreshold: UFix64 = 1.0
    var pool <- AlpenFlow.createTestPool(defaultTokenThreshold: defaultThreshold)

    // 2. Obtain an auth reference that grants EPosition access so we can call deposit/withdraw
    let poolRef = &pool as auth(AlpenFlow.EPosition) &AlpenFlow.Pool

    // 3. Open a new empty position inside the pool
    let pid = poolRef.createPosition()
    
    // 4. Create a vault with 10.0 FLOW for the deposit
    let depositVault <- AlpenFlow.createTestVault(balance: 10.0)
    
    // 5. Perform the deposit
    poolRef.deposit(pid: pid, funds: <- depositVault)

    // 6. Immediately withdraw the exact same amount
    let withdrawn <- poolRef.withdraw(
        pid: pid,
        amount: 10.0,
        type: Type<@AlpenFlow.FlowVault>()
    ) as! @AlpenFlow.FlowVault

    // 7. Assertions
    Test.assertEqual(10.0, withdrawn.balance)                                // withdraw returns 10 FLOW
    Test.assertEqual(0.0, poolRef.reserveBalance(type: Type<@AlpenFlow.FlowVault>())) // reserves unchanged (back to 0)
    Test.assertEqual(1.0, poolRef.positionHealth(pid: pid))                  // health == 1

    // 8. Clean-up resources to avoid leaks
    destroy withdrawn
    destroy pool
} 