import "FlowALPv0"
import "FlowALPModels"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
<<<<<<< HEAD
        let claimed =
            user.inbox.claim<
                auth(FlowALPv0.EParticipant) &FlowALPv0.Pool
=======
        let claimed: Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool> =
            user.inbox.claim<
                auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool
>>>>>>> main
                >("FlowALPv0BetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: FlowALPv0.PoolCapStoragePath) != nil {
            let _ = user.storage.load<
<<<<<<< HEAD
                Capability<auth(FlowALPv0.EParticipant) &FlowALPv0.Pool>
=======
                Capability<auth(FlowALPModels.EParticipant, FlowALPModels.EPosition) &FlowALPv0.Pool>
>>>>>>> main
            >(from: FlowALPv0.PoolCapStoragePath)
        }
        user.storage.save(claimed, to: FlowALPv0.PoolCapStoragePath)
    }
}


