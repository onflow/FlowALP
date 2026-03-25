import "FlowALPv0"
import "FlowALPModels"

transaction(grantee: Address) {

    prepare(admin: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account) {
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

        assert(poolCap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(poolCap, name: "FlowALPv0BetaCap", recipient: grantee)
    }
}
