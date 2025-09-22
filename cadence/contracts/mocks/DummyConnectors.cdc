import "DeFiActions"
import "FungibleToken"
import "MOET"

access(all) contract DummyConnectors {

    // Minimal sink for tests that accepts MOET and does nothing.
    access(all) struct DummySink: DeFiActions.Sink {
        // Must match the interface’s access modifier
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init() {
            self.uniqueID = nil
        }

        // ---- DeFiActions.Sink API ----
        access(all) view fun getSinkType(): Type {
            return Type<@MOET.Vault>()
        }

        access(all) fun minimumCapacity(): UFix64 {
            return UFix64.max
        }

        access(all) fun depositCapacity(from: auth(FungibleToken.Withdraw) &{FungibleToken.Vault}) {
            // no-op
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(
                type: self.getType(),
                id: self.id(),
                innerComponents: []
            )
        }

        // ---- Identity helpers (must be access(contract) to match interface) ----
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? {
            return self.uniqueID
        }

        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) {
            self.uniqueID = id
        }
    }
}
