import "TidalProtocol"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        let claimed: Capability<auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool> =
            user.inbox.claim<
                auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool
                >("TidalProtocolBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: TidalProtocol.PoolCapStoragePath) != nil {
            let _ = user.storage.load<
                Capability<auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool>
            >(from: TidalProtocol.PoolCapStoragePath)
        }
        user.storage.save(claimed, to: TidalProtocol.PoolCapStoragePath)
    }
}


