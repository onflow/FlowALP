import "FlowALPv1"

transaction() {

    prepare(
        admin: auth(Capabilities, Storage) &Account,
        tester: auth(Storage) &Account
    ) {
        let poolCap: Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool
            >(FlowALPv1.PoolStoragePath)
        // assert(poolCap.check(), message: "Failed to issue Pool capability")

        if tester.storage.type(at: FlowALPv1.PoolCapStoragePath) != nil {
            tester.storage.load<Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool>>(
                from: FlowALPv1.PoolCapStoragePath
            )
        }

        tester.storage.save(poolCap, to: FlowALPv1.PoolCapStoragePath)
    }
}
