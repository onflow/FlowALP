import "TidalProtocol"
import "MockTidalProtocolConsumer"
import "MOET"

access(all) fun main(userAddress: Address, wrapperPath: StoragePath): String {
    let account = getAccount(userAddress)
    
    // Try to borrow the wrapper
    if let wrapper = account.storage.borrow<&MockTidalProtocolConsumer.PositionWrapper>(from: wrapperPath) {
        let position = wrapper.borrowPosition()
        
        // Get position balances
        let balances = position.getBalances()
        let health = position.getHealth()
        
        var result = "Position Details:\n"
        result = result.concat("Health: ").concat(health.toString()).concat("\n")
        result = result.concat("Balances:\n")
        
        for balance in balances {
            let direction = balance.direction == TidalProtocol.BalanceDirection.Credit ? "Credit" : "Debit"
            result = result.concat("  - Token: ").concat(balance.vaultType.identifier)
                .concat(" | Direction: ").concat(direction)
                .concat(" | Amount: ").concat(balance.balance.toString()).concat("\n")
        }
        
        return result
    }
    
    return "No position wrapper found at path"
} 