import "FlowALP"

transaction() {

    prepare(
        admin: auth(Capabilities, Storage) &Account,
        tester: auth(Storage) &Account
    ) {
        let poolCap: Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool
            >(FlowALP.PoolStoragePath)
        // assert(poolCap.check(), message: "Failed to issue Pool capability")

        if tester.storage.type(at: FlowALP.PoolCapStoragePath) != nil {
            tester.storage.load<Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>>(
                from: FlowALP.PoolCapStoragePath
            )
        }

        tester.storage.save(poolCap, to: FlowALP.PoolCapStoragePath)
    }
}
