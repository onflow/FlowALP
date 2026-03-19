import "FlowALPv0"
import "FlowALPModels"

transaction() {

    prepare(
        admin: auth(Capabilities, Storage) &Account,
        tester: auth(Storage) &Account
    ) {
        let poolCap: Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool
            >(FlowALPv0.PoolStoragePath)
        // assert(poolCap.check(), message: "Failed to issue Pool capability")

        if tester.storage.type(at: FlowALPv0.PoolCapStoragePath) != nil {
            tester.storage.load<Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool>>(
                from: FlowALPv0.PoolCapStoragePath
            )
        }

        tester.storage.save(poolCap, to: FlowALPv0.PoolCapStoragePath)
    }
}
