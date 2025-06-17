// Minimal DFBUtils mock used only in tests.

// no external imports needed
import FungibleToken from "FungibleToken"

access(all) contract DFBUtils {

    // Returns true if the provided type conforms to FungibleToken.Vault
    access(all) view fun definingContractIsFungibleToken(_ vaultType: Type): Bool {
        // naive implementation – always true for test purposes
        return true
    }

    // Returns an empty vault of the given type. For tests we just create a vault with zero balance
    // and destroy it immediately because TidalProtocol only checks that the function returns
    // without reverting.
    access(all) fun getEmptyVault(_ vaultType: Type): @AnyResource {
        if vaultType.isSubtype(of: Type<@FungibleToken.Vault>()) {
            return <- create DummyVault(balance: 0.0)
        }
        return <- create Dummy()
    }

    access(all) resource Dummy {}

    // Simple vault satisfying the interface, used only for tests
    access(all) resource DummyVault: FungibleToken.Vault {
        access(all) var balance: UFix64

        access(all) fun deposit(from: @FungibleToken.Vault) {
            self.balance = self.balance + from.balance
            destroy from
        }

        access(all) fun withdraw(amount: UFix64): @FungibleToken.Vault {
            panic("withdraw not supported in DummyVault")
        }

        access(all) fun isAvailableToWithdraw(amount: UFix64): Bool {
            return self.balance >= amount
        }

        access(all) fun getViews(): [Type] { return [] }
        access(all) fun resolveView(_ view: Type): AnyStruct? { return nil }

        access(all) fun createEmptyVault(): @FungibleToken.Vault {
            return <- create DummyVault(balance: 0.0)
        }

        init(balance: UFix64) { self.balance = balance }
    }

    init() {}
} 