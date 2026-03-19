import FlowALPv0 from "FlowALPv0"
import FungibleToken from "FungibleToken"
import "FlowALPModels"

/// Withdraws stability funds collected from stability fees for a specific token type.
///
/// Only governance-authorized accounts can execute this transaction.
///
/// @param tokenTypeIdentifier: The fully qualified type identifier of the token (e.g., "A.0x1.FlowToken.Vault")
/// @param amount: The amount to withdraw from the stability fund
/// @param recipientAddress: The address to receive the withdrawn funds
/// @param recipientPath: The public path where the recipient's Receiver capability is published
transaction(
    tokenTypeIdentifier: String,
    amount: UFix64,
    recipient: Address,
    recipientPath: PublicPath,
) {
    let pool: auth(FlowALPModels.EGovernance) &FlowALPv0.Pool
    let tokenType: Type
    let recipient: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPModels.EGovernance) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowALPv0.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")

        self.recipient = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(recipientPath)
            ?? panic("Could not borrow receiver ref")
    }

    execute {
        self.pool.withdrawStabilityFund(
            tokenType: self.tokenType,
            amount: amount,
            recipient: self.recipient
        )
    }
} 
