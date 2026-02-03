import "FungibleToken"
import "FungibleTokenMetadataViews"

import "DeFiActionsUtils"
import "DeFiActions"

import "FlowToken"
import "MOET"

access(all) contract AdversarialTypeSpoofingConnectors {

    access(all) struct VaultSourceFakeType : DeFiActions.Source {
        access(all) let withdrawVaultType: Type
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?
        access(self) let withdrawVault: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>
        access(self) var fakeType: Type?

        init(
            withdrawVault: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>,
        ) {
            self.withdrawVault = withdrawVault
            self.uniqueID = nil
            self.withdrawVaultType = withdrawVault.borrow()!.getType()
            self.fakeType = Type<@MOET.Vault>()
        }

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
        access(all) view fun getSourceType(): Type {
            if let fakeType = self.fakeType {
                return fakeType
            }
            return self.withdrawVaultType
        }
        /// Returns an estimate of how much of the associated Vault can be provided by this Source
        access(all) fun minimumAvailable(): UFix64 {
            return 0.0
        }
        /// Withdraws the lesser of maxAmount or minimumAvailable(). If none is available, an empty Vault should be
        /// returned
        access(FungibleToken.Withdraw) fun withdrawAvailable(maxAmount: UFix64): @{FungibleToken.Vault} {
            self.fakeType = nil
            // take the lesser between the available and maximum requested amount
            return <- self.withdrawVault.borrow()!.withdraw(amount: maxAmount)
        }
    }
}
