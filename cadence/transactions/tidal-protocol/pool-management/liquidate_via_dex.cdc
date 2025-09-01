import "FungibleToken"
import "TidalProtocol"
import "DeFiActions"
import "IncrementFiSwapConnectors"

/// Liquidate a position via DEX: seize collateral, swap via allowlisted Swapper to debt token, repay debt
transaction(
    pid: UInt64,
    debtVaultIdentifier: String,
    seizeVaultIdentifier: String,
    path: [String],
    maxSeizeAmount: UFix64,
    minRepayAmount: UFix64
) {
    let pool: &TidalProtocol.Pool
    let debtType: Type
    let seizeType: Type
    let swapper: {DeFiActions.Swapper}

    prepare(signer: auth(BorrowValue) &Account) {
        let protocolAddress = Type<@TidalProtocol.Pool>().address!
        self.pool = getAccount(protocolAddress).capabilities.borrow<&TidalProtocol.Pool>(TidalProtocol.PoolPublicPath)
            ?? panic("Could not borrow Pool at \(TidalProtocol.PoolPublicPath)")

        self.debtType = CompositeType(debtVaultIdentifier) ?? panic("Invalid debtVaultIdentifier: \(debtVaultIdentifier)")
        self.seizeType = CompositeType(seizeVaultIdentifier) ?? panic("Invalid seizeVaultIdentifier: \(seizeVaultIdentifier)")
        // Instantiate IncrementFi swapper for provided path
        self.swapper = IncrementFiSwapConnectors.Swapper(
            path: path,
            inVault: self.seizeType,
            outVault: self.debtType,
            uniqueID: nil
        )
    }

    execute {
        self.pool.liquidateViaDex(
            pid: pid,
            debtType: self.debtType,
            seizeType: self.seizeType,
            maxSeizeAmount: maxSeizeAmount,
            minRepayAmount: minRepayAmount,
            swapper: self.swapper,
            quote: nil
        )
    }
}


