import TidalProtocol from "TidalProtocol"

transaction(positionID: UInt64, amount: UFix64) {
    prepare(signer: auth(Storage) &Account) {
        // Get the pool reference from storage
        let pool = signer.storage.borrow<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(
            from: /storage/testPool
        ) ?? panic("Could not borrow Pool reference")
        
        // Create a MockVault with the specified amount
        // Note: In a real scenario, this would come from the signer's vault
        // For testing, we'll create it on the fly
        let mockVault <- TestHelpers.createTestVault(balance: amount)
        
        // Deposit into the position
        pool.deposit(pid: positionID, funds: <-mockVault)
        
        log("Deposited ".concat(amount.toString()).concat(" into position ").concat(positionID.toString()))
    }
} 