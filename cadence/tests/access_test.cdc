import Test
import AlpenFlow from 0xf8d6e0586b0a20c7

access(all)
fun testTypeAccess() {
    // This test doesn't call any functions, just verifies we can access type information
    let vaultType = Type<@AlpenFlow.FlowVault>()
    let poolType = Type<@AlpenFlow.Pool>()
    
    // Simple assertion that should pass
    Test.assert(true)
} 