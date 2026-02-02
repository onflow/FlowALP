import "FlowALPv1"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        let claimed: Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool> =
            user.inbox.claim<
                auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool
                >("FlowALPv1BetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: FlowALPv1.PoolCapStoragePath) != nil {
            let _ = user.storage.load<
                Capability<auth(FlowALPv1.EParticipant, FlowALPv1.EPosition) &FlowALPv1.Pool>
            >(from: FlowALPv1.PoolCapStoragePath)
        }
        user.storage.save(claimed, to: FlowALPv1.PoolCapStoragePath)
    }
}


