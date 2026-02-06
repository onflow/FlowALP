import "FlowCreditMarket"

transaction() {

    prepare(
        admin: auth(Capabilities, Storage) &Account,
        tester: auth(Storage) &Account
    ) {
        let poolCap: Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition, FlowCreditMarket.ERebalance) &FlowCreditMarket.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition, FlowCreditMarket.ERebalance) &FlowCreditMarket.Pool
            >(FlowCreditMarket.PoolStoragePath)
        // assert(poolCap.check(), message: "Failed to issue Pool capability")

        if tester.storage.type(at: FlowCreditMarket.PoolCapStoragePath) != nil {
            tester.storage.load<Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition, FlowCreditMarket.ERebalance) &FlowCreditMarket.Pool>>(
                from: FlowCreditMarket.PoolCapStoragePath
            )
        }

        tester.storage.save(poolCap, to: FlowCreditMarket.PoolCapStoragePath)
    }
}
