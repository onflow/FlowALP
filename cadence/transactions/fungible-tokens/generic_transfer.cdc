import "FungibleToken"
import "FungibleTokenMetadataViews"

/// Transfers fungible tokens from the signer to a recipient using the token's identifier
///
/// @param tokenIdentifier: The identifier of the Vault type (e.g., "A.0x1654653399040a61.FlowToken.Vault")
/// @param amount: The amount of tokens to transfer
/// @param recipient: The address to receive the tokens
transaction(tokenIdentifier: String, amount: UFix64, recipient: Address) {
    let sentVault: @{FungibleToken.Vault}
    let receiverRef: &{FungibleToken.Receiver}

    prepare(signer: auth(BorrowValue) &Account) {
        // Resolve the Vault type from identifier
        let vaultType = CompositeType(tokenIdentifier)
            ?? panic("Invalid Vault identifier: \(tokenIdentifier)")

        let contractAddress = vaultType.address
            ?? panic("Could not derive contract address from identifier: \(tokenIdentifier)")
        let contractName = vaultType.contractName
            ?? panic("Could not derive contract name from identifier: \(tokenIdentifier)")

        // Borrow the contract and resolve FTVaultData
        let ftContract = getAccount(contractAddress).contracts.borrow<&{FungibleToken}>(name: contractName)
            ?? panic("No such FungibleToken contract found")

        let data = ftContract.resolveContractView(
            resourceType: vaultType,
            viewType: Type<FungibleTokenMetadataViews.FTVaultData>()
        ) as! FungibleTokenMetadataViews.FTVaultData?
            ?? panic("Could not resolve FTVaultData for Vault type: \(tokenIdentifier)")

        // Borrow signer's vault and withdraw tokens
        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(
            from: data.storagePath
        ) ?? panic("Could not borrow reference to signer's vault at path: \(data.storagePath.toString())")

        self.sentVault <- vaultRef.withdraw(amount: amount)

        // Get recipient's receiver capability
        self.receiverRef = getAccount(recipient).capabilities.borrow<&{FungibleToken.Receiver}>(
            data.receiverPath
        ) ?? panic("Could not borrow receiver reference for recipient at path: \(data.receiverPath.toString())")
    }

    execute {
        self.receiverRef.deposit(from: <-self.sentVault)
    }
}