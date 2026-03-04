import "FlowALPv0"

transaction {
    let pool: auth(FlowALPv0.EImplementation) &FlowALPv0.Pool

    prepare(signer: auth(BorrowValue) &Account) {
        self.pool = signer.storage.borrow<auth(FlowALPv0.EImplementation) &FlowALPv0.Pool>(from: FlowALPv0.PoolStoragePath)
            ?? panic("Could not borrow Pool")
    }

    execute {
        self.pool.asyncUpdate()
    }
}
