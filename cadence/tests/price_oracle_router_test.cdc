import Test
import BlockchainHelpers

import "FlowPriceOracleRouterv1"
import "FlowToken"
import "MOET"
import "ExampleToken1"
import "ExampleToken2"
import "test_helpers.cdc"
import "test_helpers_price_oracle_router.cdc"

access(all) var snapshot: UInt64 = 0

access(all) fun setup() {
    deployContracts()
    snapshot = getCurrentBlockHeight()
}

access(all) fun beforeEach() {
    if snapshot != getCurrentBlockHeight() {
        Test.reset(to: snapshot)
    }
}

access(all) fun test_router_add_oracle() {
    let info = [
        createPriceOracleRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@FlowToken.Vault>(),
            prices: 1.0
        )
    ]
    createPriceOracleRouter(
        unitOfAccount: Type<@MOET.Vault>(),
        createRouterInfo: info,
        expectSucceeded: true
    )
    var price = 0.0 as UFix64?
    price = priceOracleRouterPrice(ofToken: Type<@FlowToken.Vault>())
    Test.assertEqual(price, 1.0 as UFix64?)
    price = priceOracleRouterPrice(ofToken: Type<@ExampleToken1.Vault>())
    Test.assertEqual(price, nil as UFix64?)
}

access(all) fun test_router_add_multiple_oracles() {
    let info = [
        createPriceOracleRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@FlowToken.Vault>(),
            prices: 1.0
        ),
        createPriceOracleRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@ExampleToken1.Vault>(),
            prices: 2.0
        ),
        createPriceOracleRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@ExampleToken2.Vault>(),
            prices: 3.0
        )
    ]
    createPriceOracleRouter(
        unitOfAccount: Type<@MOET.Vault>(),
        createRouterInfo: info,
        expectSucceeded: true
    )
    var price = 0.0 as UFix64?
    price = priceOracleRouterPrice(ofToken: Type<@FlowToken.Vault>())
    Test.assertEqual(price, 1.0 as UFix64?)
    price = priceOracleRouterPrice(ofToken: Type<@ExampleToken1.Vault>())
    Test.assertEqual(price, 2.0 as UFix64?)
    price = priceOracleRouterPrice(ofToken: Type<@ExampleToken2.Vault>())
    Test.assertEqual(price, 3.0 as UFix64?)
}

access(all) fun test_router_add_wrong_unit_of_account() {
    let info = [
        createPriceOracleRouterInfo(
            unitOfAccount: Type<@ExampleToken1.Vault>(),
            oracleOfToken: Type<@FlowToken.Vault>(),
            prices: 1.0
        )
    ]
    createPriceOracleRouter(
        unitOfAccount: Type<@MOET.Vault>(),
        createRouterInfo: info,
        expectSucceeded: false
    )
}