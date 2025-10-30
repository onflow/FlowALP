import "FlowALP"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        let claimed: Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool> =
            user.inbox.claim<
                auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool
                >("FlowALPBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: FlowALP.PoolCapStoragePath) != nil {
            let _ = user.storage.load<
                Capability<auth(FlowALP.EParticipant, FlowALP.EPosition) &FlowALP.Pool>
            >(from: FlowALP.PoolCapStoragePath)
        }
        user.storage.save(claimed, to: FlowALP.PoolCapStoragePath)
    }
}


