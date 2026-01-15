import FlowCreditMarket from "FlowCreditMarket"
import FungibleToken from "FungibleToken"

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
    recipientPath: String,
) {
    let pool: auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool
    let tokenType: Type
    let recipient: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.EGovernance) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow Pool at \(FlowCreditMarket.PoolStoragePath)")
        self.tokenType = CompositeType(tokenTypeIdentifier)
            ?? panic("Invalid tokenTypeIdentifier \(tokenTypeIdentifier)")

        let publicPath = PublicPath(identifier: recipientPath)
            ?? panic("Invalid recipient path \(recipientPath)")
        self.recipient = getAccount(recipient)
            .capabilities.borrow<&{FungibleToken.Receiver}>(publicPath)
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
