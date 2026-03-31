import "FlowALPv0"
import "FlowALPModels"

transaction() {

    prepare(
        admin: auth(Capabilities, Storage) &Account,
        tester: auth(Storage) &Account
    ) {
        let poolCap =
            admin.capabilities.storage.issue<
                auth(FlowALPModels.EParticipant) &FlowALPv0.Pool
            >(FlowALPv0.PoolStoragePath)
        if tester.storage.type(at: FlowALPv0.PoolCapStoragePath) != nil {
            tester.storage.load<Capability<auth(FlowALPModels.EParticipant) &FlowALPv0.Pool>>(
                from: FlowALPv0.PoolCapStoragePath
            )
        }

        tester.storage.save(poolCap, to: FlowALPv0.PoolCapStoragePath)
    }
}
