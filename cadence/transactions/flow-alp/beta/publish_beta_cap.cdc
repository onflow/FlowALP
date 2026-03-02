import "FlowALPv0"
import "FlowALPModels"

transaction(grantee: Address) {

    prepare(admin: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account) {
        let poolCap: Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool
            >(FlowALPv0.PoolStoragePath)

        assert(poolCap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(poolCap, name: "FlowALPv0BetaCap", recipient: grantee)
    }
}
