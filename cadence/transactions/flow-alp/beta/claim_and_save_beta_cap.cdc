import "FlowALP"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        // Save claimed cap at the protocol-defined storage path to satisfy consumers/tests expecting this path
        let capPath = FlowALP.PoolCapStoragePath
        let claimed: Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool> =
            user.inbox.claim<
                auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool
                >("FlowALPBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: capPath) != nil {
            let _ = user.storage.load<Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>>(from: capPath)
        }
        user.storage.save(claimed, to: capPath)
    }
}
