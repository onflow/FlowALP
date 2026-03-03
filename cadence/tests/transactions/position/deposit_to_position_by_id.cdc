import "FungibleToken"
import "FlowALPv0"

/// Deposits funds to a position by position ID (using PositionManager)
///
transaction(positionId: UInt64, amount: UFix64, vaultStoragePath: StoragePath, pushToDrawDownSink: Bool) {

    let collateral: @{FungibleToken.Vault}
    let position: auth(FungibleToken.Withdraw) &FlowALPv0.Position
    let pushToDrawDownSink: Bool

    prepare(signer: auth(BorrowValue) &Account) {
        // Withdraw the collateral from the signer's stored Vault
        let collateralSource = signer.storage.borrow<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(from: vaultStoragePath)
            ?? panic("Could not borrow reference to Vault from \(vaultStoragePath)")
        self.collateral <- collateralSource.withdraw(amount: amount)

        // Borrow the PositionManager from storage
        let manager = signer.storage.borrow<auth(FungibleToken.Withdraw, FlowALPv0.EPositionAdmin) &FlowALPv0.PositionManager>(
            from: FlowALPv0.PositionStoragePath
        ) ?? panic("Could not find PositionManager in storage")

        // Borrow the position with withdraw entitlement
        self.position = manager.borrowAuthorizedPosition(pid: positionId) as! auth(FungibleToken.Withdraw) &FlowALPv0.Position
        self.pushToDrawDownSink = pushToDrawDownSink
    }

    execute {
        // Deposit to the position
        self.position.depositAndPush(from: <-self.collateral, pushToDrawDownSink: self.pushToDrawDownSink)
    }
}
