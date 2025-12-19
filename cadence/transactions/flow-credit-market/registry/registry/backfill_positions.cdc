import "FlowCreditMarket"
import "FlowCreditMarketRegistry"

/// INTENDED FOR BETA PURPOSES ONLY
///
/// This transaction will backfill all unregistered Pool positions into the Registry
transaction {

    let pool: &FlowCreditMarket.Pool
    let registry: auth(FlowCreditMarket.Register) &FlowCreditMarketRegistry.Registry
    
    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowCreditMarket.Register) &FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)
            ?? panic("Could not borrow reference to Pool from \(FlowCreditMarket.PoolStoragePath) - ensure a Pool has been configured")
        let registryPath = FlowCreditMarket.deriveRegistryStoragePath(forPool: self.pool.uuid)
        self.registry = signer.storage.borrow<auth(FlowCreditMarket.Register) &FlowCreditMarketRegistry.Registry>(from: registryPath)
            ?? panic("Could not borrow reference to Registry from \(registryPath) - ensure a Registry has been configured")
    }

    execute {
        for pid in self.pool.getPositionIDs() {
            if self.registry.registeredPositions[pid] != nil {
                continue
            }
            self.registry.registerPosition(poolUUID: self.pool.uuid, pid: pid, rebalanceConfig: nil)
        }
    }
}
