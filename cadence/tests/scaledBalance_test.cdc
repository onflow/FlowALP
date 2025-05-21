import Test
import AlpenFlow from 0xf8d6e0586b0a20c7

/*
 * TROUBLESHOOTING NOTES FOR FLOW ENGINEERS:
 * 
 * Issue: "failed to load contract: f8d6e0586b0a20c7.AlpenFlow" at line 16
 * 
 * Relevant debugging information:
 * 1. This test tries to call the scaledBalanceToTrueBalance function
 * 2. Originally this function had access(self), but we changed it to access(all)
 * 3. Despite this change, the test still fails when trying to call the function
 * 4. Other utility functions in the contract were also changed from access(self) to access(all)
 *
 * We suspect this might be related to how the contract is loaded by the test runner
 * when utility functions are called directly, even when they don't involve resources.
 */

access(all)
fun testScaledBalance() {
    /* 
     * This test verifies that the scaledBalanceToTrueBalance function 
     * correctly converts scaled balances to true balances based on the interest index
     */
    
    // 1. Set up test values
    let scaledBalance: UFix64 = 100.0
    let interestIndex: UInt64 = 10000000000000000 // 1.0 as a fixed point with 16 decimals
    
    // 2. Call the conversion function
    let trueBalance = AlpenFlow.scaledBalanceToTrueBalance(
        scaledBalance: scaledBalance, 
        interestIndex: interestIndex
    )
    
    // 3. If the interest index is 1.0, the true balance should equal the scaled balance
    Test.assertEqual(100.0, trueBalance)
    
    // 4. Test with a different interest index (1.05 = 5% interest accrued)
    let higherIndex: UInt64 = 10500000000000000 // 1.05 as a fixed point
    let adjustedBalance = AlpenFlow.scaledBalanceToTrueBalance(
        scaledBalance: scaledBalance,
        interestIndex: higherIndex
    )
    
    // 5. The true balance should now be 5% higher than the scaled balance
    Test.assert(adjustedBalance > scaledBalance)
    Test.assertEqual(105.0, adjustedBalance)
} 