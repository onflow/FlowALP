import "FlowALPv0"

transaction(grantee: Address) {

    prepare(admin: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account) {
        let poolCap: Capability<auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALPv0.EParticipant, FlowALPv0.EPosition) &FlowALPv0.Pool
            >(FlowALPv0.PoolStoragePath)

        assert(poolCap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(poolCap, name: "FlowALPv0BetaCap", recipient: grantee)
    }
}
