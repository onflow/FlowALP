import Test
import AlpenFlow from 0xf8d6e0586b0a20c7

/*
 * TROUBLESHOOTING NOTES FOR FLOW ENGINEERS:
 * 
 * Issue: "failed to load contract: f8d6e0586b0a20c7.AlpenFlow" at line 12
 * 
 * Relevant debugging information:
 * 1. The contract is deployed to the emulator account (0xf8d6e0586b0a20c7)
 * 2. Simple tests with no resource interaction work fine
 * 3. This test fails when trying to call createTestVault(), despite it being declared
 *    with access(all) in the contract
 *
 * This test is meant to be the simplest possible test that interacts with a resource helper.
 * If this test doesn't work, it suggests an issue with the test runner's ability to resolve
 * resource-creating functions in the contract.
 */

access(all)
fun testMiniCore() {
    /* 
     * This test verifies that we can create a FlowVault with a specified 
     * balance using the createTestVault helper function
     */
     
    // 1. Create a FlowVault with a balance of 10.0
    let vault <- AlpenFlow.createTestVault(balance: 10.0)
    
    // 2. Verify the balance is 10.0
    Test.assertEqual(10.0, vault.balance)
    
    // 3. Clean up
    destroy vault
} 