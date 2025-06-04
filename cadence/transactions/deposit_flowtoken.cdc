import FlowToken from "FlowToken"
import FungibleToken from "FungibleToken"
import TidalProtocol from "TidalProtocol"

transaction(positionID: UInt64, amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        // Get a reference to the signer's FlowToken vault
        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow reference to the owner's FlowToken Vault!")
        
        // Withdraw the FlowToken from the signer's vault
        let flowVault <- vaultRef.withdraw(amount: amount)
        
        // This transaction assumes the pool is stored in the signer's account
        // Get the pool reference
        let pool = signer.storage.borrow<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(
            from: /storage/tidalPool
        ) ?? panic("Could not borrow Pool reference")
        
        // Deposit into the position
        pool.deposit(pid: positionID, funds: <-flowVault)
    }
} 