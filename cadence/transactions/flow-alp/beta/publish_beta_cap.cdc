import "FlowALPv1"

transaction(grantee: Address) {

    prepare(admin: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account) {
        let poolCap: Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool
            >(FlowALPv1.PoolStoragePath)

        assert(poolCap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(poolCap, name: "FlowALPv1BetaCap", recipient: grantee)
    }
}
