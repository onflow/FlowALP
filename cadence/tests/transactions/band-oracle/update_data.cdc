import "BandOracle"

/// TEST TRANSACTION - NOT FOR USE IN PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// Updates the BandOracle contract with the provided prices
///
/// @param symbolsRates: Mapping of symbols to prices where prices are USD-rate multiplied by 1e9
///
transaction(symbolsRates: {String: UInt64}) {
    let updater: &BandOracle.BandOracleAdmin
    prepare(signer: auth(BorrowValue) &Account) {
        self.updater = signer.storage.borrow<&BandOracle.BandOracleAdmin>(from: BandOracle.OracleAdminStoragePath)
            ?? panic("Could not find DataUpdater at \(BandOracle.OracleAdminStoragePath)")
    }
    execute {
        self.updater.updateData(
            symbolsRates: symbolsRates,
            resolveTime: UInt64(getCurrentBlock().timestamp),
            requestID: revertibleRandom<UInt64>(),
            relayerID: revertibleRandom<UInt64>()
        )
    }
}
