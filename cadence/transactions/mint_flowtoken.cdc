import FlowToken from "FlowToken"
import FungibleToken from "FungibleToken"

transaction(recipient: Address, amount: UFix64) {
    prepare(signer: auth(BorrowValue) &Account) {
        let minter = signer.storage.borrow<&FlowToken.Minter>(from: /storage/flowTokenMinter)
            ?? panic("Could not borrow minter")
        
        let newVault <- minter.mintTokens(amount: amount)
        
        let receiverRef = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Could not borrow receiver reference")
            
        receiverRef.deposit(from: <-newVault)
    }
} 