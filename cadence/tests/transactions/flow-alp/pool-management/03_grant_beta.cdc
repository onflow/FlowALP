import "FlowALPv0"
import "FlowALPModels"

transaction() {

    prepare(
        admin: auth(Capabilities, Storage) &Account,
        tester: auth(Storage) &Account
    ) {
<<<<<<< HEAD
        let poolCap =
            admin.capabilities.storage.issue<
                auth(FlowALPv0.EParticipant) &FlowALPv0.Pool
=======
        let poolCap: Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool
>>>>>>> main
            >(FlowALPv0.PoolStoragePath)
        // assert(poolCap.check(), message: "Failed to issue Pool capability")

        if tester.storage.type(at: FlowALPv0.PoolCapStoragePath) != nil {
<<<<<<< HEAD
            tester.storage.load<Capability<auth(FlowALPv0.EParticipant) &FlowALPv0.Pool>>(
=======
            tester.storage.load<Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool>>(
>>>>>>> main
                from: FlowALPv0.PoolCapStoragePath
            )
        }

        tester.storage.save(poolCap, to: FlowALPv0.PoolCapStoragePath)
    }
}
