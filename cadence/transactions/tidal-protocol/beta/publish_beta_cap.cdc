import "TidalProtocol"

transaction(grantee: Address) {

    prepare(admin: auth(IssueStorageCapabilityController, PublishInboxCapability) &Account) {
        let poolCap: Capability<auth(TidalProtocol.EPosition) &TidalProtocol.Pool> =
            admin.capabilities.storage.issue<
                auth(TidalProtocol.EPosition) &TidalProtocol.Pool
            >(TidalProtocol.PoolStoragePath)

        assert(poolCap.check(), message: "Failed to issue beta capability")

        admin.inbox.publish(poolCap, name: "TidalProtocolBetaCap", recipient: grantee)
    }
}
