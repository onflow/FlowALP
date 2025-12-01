import "FlowCreditMarket"

transaction(adminAddr: Address) {

    prepare(user: auth(SaveValue, LoadValue, ClaimInboxCapability) &Account) {
        let claimed: Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool> =
            user.inbox.claim<
                auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool
                >("FlowCreditMarketBetaCap", provider: adminAddr)
                ?? panic("No beta capability found in inbox")

        if user.storage.type(at: FlowCreditMarket.PoolCapStoragePath) != nil {
            let _ = user.storage.load<
                Capability<auth(FlowCreditMarket.EParticipant, FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>
            >(from: FlowCreditMarket.PoolCapStoragePath)
        }
        user.storage.save(claimed, to: FlowCreditMarket.PoolCapStoragePath)
    }
}


