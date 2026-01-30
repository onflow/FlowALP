import "DeFiActions"
import "FungibleToken"
import "MOET"

access(all) contract SimpleSinkSource {

    // Simple sink and source for tests that accepts MOET and does nothing.
    access(all) struct SinkSource: DeFiActions.Sink, DeFiActions.Source {
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(all) let type: Type
        access(all) let vault: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>

        init(vault: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>) {
            self.uniqueID = nil
            self.type = vault.borrow()!.getType()
            self.vault = vault
        }

        // ---- DeFiActions.Sink API ----
        access(all) view fun getSinkType(): Type {
            return self.type
        }

        access(all) fun minimumCapacity(): UFix64 {
            return UFix64.max
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            self.vault.borrow()!.deposit(from: <-from.withdraw(amount: from.balance))
        }

        // ---- DeFiActions.Source API ----
        access(all) view fun getSourceType(): Type {
            return self.type
        }

        access(all) fun minimumAvailable(): UFix64 {
            return self.vault.borrow()!.balance
        }

        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            return <- self.vault.borrow()!.withdraw(amount: maxAmount)
        }

        // ---- DeFiActions.Source and DeFiActions.Sink API ----
        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }
}
