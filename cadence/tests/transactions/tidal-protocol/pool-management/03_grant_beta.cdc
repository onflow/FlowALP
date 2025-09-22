import "TidalProtocol"

transaction() {

    prepare(
        admin: auth(Capabilities, Storage) &Account,
        tester: auth(Storage) &Account
    ) {
        let poolCap: Capability<auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool> =
            admin.capabilities.storage.issue<
                auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool
            >(TidalProtocol.PoolStoragePath)
        // assert(poolCap.check(), message: "Failed to issue Pool capability")

        if tester.storage.type(at: TidalProtocol.PoolCapStoragePath) != nil {
            tester.storage.load<Capability<auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool>>(
                from: TidalProtocol.PoolCapStoragePath
            )
        }

        tester.storage.save(poolCap, to: TidalProtocol.PoolCapStoragePath)
    }
}
