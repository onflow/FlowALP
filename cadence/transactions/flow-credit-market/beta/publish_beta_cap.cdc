import "FlowCreditMarket"

transaction(grantee: Address) {

    prepare(admin: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account) {
        let poolCap: Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool> =
            admin.capabilities.storage.issue<
                auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool
            >(FlowCreditMarket.PoolStoragePath)

        assert(poolCap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(poolCap, name: "FlowCreditMarketBetaCap", recipient: grantee)
    }
}
