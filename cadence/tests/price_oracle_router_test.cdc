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
    Test.commitBlock()
    Test.reset(to: snapshot)
}

access(all) fun test_router_add_oracle() {
    let info = [
        createRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@FlowToken.Vault>(),
            prices: 1.0
        )
    ]
    createRouter(
        unitOfAccount: Type<@MOET.Vault>(),
        createRouterInfo: info,
        expectSucceeded: true
    )
    Test.assertEqual(price(ofToken: Type<@FlowToken.Vault>()), 1.0 as UFix64?)
    Test.assertEqual(price(ofToken: Type<@ExampleToken1.Vault>()), nil as UFix64?)
}

access(all) fun test_router_add_multiple_oracles() {
    let info = [
        createRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@FlowToken.Vault>(),
            prices: 1.0
        ),
        createRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@ExampleToken1.Vault>(),
            prices: 2.0
        ),
        createRouterInfo(
            unitOfAccount: Type<@MOET.Vault>(),
            oracleOfToken: Type<@ExampleToken2.Vault>(),
            prices: 3.0
        )
    ]
    createRouter(
        unitOfAccount: Type<@MOET.Vault>(),
        createRouterInfo: info,
        expectSucceeded: true
    )
    Test.assertEqual(price(ofToken: Type<@FlowToken.Vault>()), 1.0 as UFix64?)
    Test.assertEqual(price(ofToken: Type<@ExampleToken1.Vault>()), 2.0 as UFix64?)
    Test.assertEqual(price(ofToken: Type<@ExampleToken2.Vault>()), 3.0 as UFix64?)
}

access(all) fun test_router_add_wrong_unit_of_account() {
    let createRouterInfo = [
        createRouterInfo(
            unitOfAccount: Type<@ExampleToken1.Vault>(),
            oracleOfToken: Type<@FlowToken.Vault>(),
            prices: 1.0
        )
    ]
    createRouter(
        unitOfAccount: Type<@MOET.Vault>(),
        createRouterInfo: createRouterInfo,
        expectSucceeded: false
    )
}