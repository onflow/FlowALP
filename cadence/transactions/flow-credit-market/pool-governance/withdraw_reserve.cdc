// NOTE: This is a scaffold transaction; update when contract functions are finalised

import FlowCreditMarket from "FlowCreditMarket"
import FungibleToken from "FungibleToken"
import MOET from "MOET"

// Governance-authorised withdrawal of pool reserve tokens
// Parameters:
//  - poolAddress: Address of the pool smart-contract account
//  - tokenTypeIdentifier: String identifier (e.g. "A.7e60...FlowToken.Vault")
//  - amount: amount to withdraw
//  - recipient: treasury or destination account
//
// Executes as the governance admin (signer).
transaction(poolAddress: Address, tokenTypeIdentifier: String, amount: UFix64, recipient: Address) {
    prepare(signer: auth(BorrowValue) &Account) {
        // TODO: Implement proper governance control
        // For now, we'll check if the signer is the pool address (protocol account)
        if signer.address != poolAddress {
            panic("Unauthorized: Only pool governance can withdraw reserves")
        }

        // TODO: Once FlowCreditMarket.Pool exposes a withdrawReserve function, use it
        // For now, this is a placeholder that will always succeed for the protocol account
        // and fail for others (as checked above)
        
        // Create empty vault for testing purposes
        let emptyVault <- MOET.createEmptyVault(vaultType: Type<@MOET.Vault>())
        
        // Get the receiver capability based on token type
        let receiverPath: PublicPath = tokenTypeIdentifier == "A.0000000000000007.MOET.Vault" 
            ? MOET.ReceiverPublicPath 
            : /public/flowTokenReceiver
            
        let receiver = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(receiverPath)
            ?? panic("Could not borrow receiver ref")
            
        receiver.deposit(from: <- emptyVault)
    }
} 
