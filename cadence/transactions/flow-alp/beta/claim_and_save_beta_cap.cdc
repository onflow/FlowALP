import "FlowALPv1"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        // Save claimed cap at the protocol-defined storage path to satisfy consumers/tests expecting this path
        let capPath = FlowALPv1.PoolCapStoragePath
        let claimed: Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool> =
            user.inbox.claim<
                auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool
                >("FlowALPv1BetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: capPath) != nil {
            let _ = user.storage.load<Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool>>(from: capPath)
        }
        user.storage.save(claimed, to: capPath)
    }
}
