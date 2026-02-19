import "FlowALPv0"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        // Save claimed cap at the protocol-defined storage path to satisfy consumers/tests expecting this path
        let capPath = FlowALPv0.PoolCapStoragePath
        let claimed: Capability<auth(FlowALPv0.EParticipant) &FlowALPv0.Pool> =
            user.inbox.claim<
                auth(FlowALPv0.EParticipant) &FlowALPv0.Pool
                >("FlowALPv0BetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: capPath) != nil {
            let _ = user.storage.load<Capability<auth(FlowALPv0.EParticipant) &FlowALPv0.Pool>>(from: capPath)
        }
        user.storage.save(claimed, to: capPath)
    }
}
