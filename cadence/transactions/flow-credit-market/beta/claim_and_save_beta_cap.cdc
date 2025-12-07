import "FlowCreditMarket"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        // Save claimed cap at the protocol-defined storage path to satisfy consumers/tests expecting this path
        let capPath = FlowCreditMarket.PoolCapStoragePath
        let claimed: Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool> =
            user.inbox.claim<
                auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool
                >("FlowCreditMarketBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: capPath) != nil {
            let _ = user.storage.load<Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>>(from: capPath)
        }
        user.storage.save(claimed, to: capPath)
    }
}
