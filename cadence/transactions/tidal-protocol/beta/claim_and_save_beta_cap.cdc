import "TidalProtocol"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        // Save claimed cap at the protocol-defined storage path to satisfy consumers/tests expecting this path
        let capPath = TidalProtocol.PoolCapStoragePath
        let claimed: Capability<auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool> =
            user.inbox.claim<
                auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool
                >("TidalProtocolBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: capPath) != nil {
            let _ = user.storage.load<Capability<auth(TidalProtocol.EParticipant, TidalProtocol.EPosition) &TidalProtocol.Pool>>(from: capPath)
        }
        user.storage.save(claimed, to: capPath)
    }
}
