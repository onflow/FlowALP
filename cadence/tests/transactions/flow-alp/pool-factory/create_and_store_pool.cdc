import "FungibleToken"

import "DeFiActions"
import "FlowALPv1"
import "MockOracle"
import "MockDexSwapper"

/// THIS TRANSACTION IS NOT INTENDED FOR PRODUCTION
/// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
///
/// Creates the protocol pool in the FlowALPv1 account via the stored PoolFactory resource
///
/// @param defaultTokenIdentifier: The Type identifier (e.g. resource.getType().identifier) of the Pool's default token
///
transaction(defaultTokenIdentifier: String) {

    let factory: &FlowALPv1.PoolFactory
    let defaultToken: Type
    let oracle: {DeFiActions.PriceOracle}
    let dex: {DeFiActions.SwapperProvider}

    prepare(signer: auth(BorrowValue) &Account) {
        self.factory = signer.storage.borrow<&FlowALPv1.PoolFactory>(from: FlowALPv1.PoolFactoryPath)
            ?? panic("Could not find PoolFactory in signer's account")
        self.defaultToken = CompositeType(defaultTokenIdentifier) ?? panic("Invalid defaultTokenIdentifier \(defaultTokenIdentifier)")
        self.oracle = MockOracle.PriceOracle()
        self.dex = MockDexSwapper.SwapperProvider()
    }

    execute {
        self.factory.createPool(defaultToken: self.defaultToken, priceOracle: self.oracle, dex: self.dex)
    }
}