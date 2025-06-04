import FlowToken from "FlowToken"
import FungibleToken from "FungibleToken"
import TidalProtocol from "TidalProtocol"

transaction(positionID: UInt64, amount: UFix64) {
    prepare(signer: auth(BorrowValue, SaveValue) &Account) {
        // This transaction assumes the pool is stored in the signer's account
        // Get the pool reference
        let pool = signer.storage.borrow<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>(
            from: /storage/tidalPool
        ) ?? panic("Could not borrow Pool reference")
        
        // Withdraw (borrow) FlowToken from the position
        let borrowedVault <- pool.withdraw(
            pid: positionID, 
            amount: amount, 
            type: Type<@FlowToken.Vault>()
        )
        
        // Get the signer's FlowToken receiver
        let receiverRef = signer.capabilities.borrow<&{FungibleToken.Receiver}>(
            /public/flowTokenReceiver
        ) ?? panic("Could not borrow receiver reference to the recipient's FlowToken Vault")
        
        // Deposit the borrowed FlowToken into the signer's vault
        receiverRef.deposit(from: <-borrowedVault)
    }
} 