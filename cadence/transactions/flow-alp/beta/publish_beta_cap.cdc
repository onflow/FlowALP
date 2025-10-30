import "FlowALP"

transaction(grantee: Address) {

    prepare(admin: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account) {
        let poolCap: Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool
            >(FlowALP.PoolStoragePath)

        assert(poolCap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(poolCap, name: "FlowALPBetaCap", recipient: grantee)
    }
}
