import "TidalProtocol"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        let capPath = /storage/tidalProtocolPoolCap_for_tests
        let claimed: Capability<auth(TidalProtocol.EPosition) &TidalProtocol.Pool> =
            user.inbox.claim<
                auth(TidalProtocol.EPosition) &TidalProtocol.Pool
                >("TidalProtocolBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: capPath) != nil {
            let _ = user.storage.load<Capability<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>>(from: capPath)
        }
        user.storage.save(claimed, to: capPath)
    }
}
