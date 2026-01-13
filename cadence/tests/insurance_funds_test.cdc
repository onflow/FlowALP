import Test

import "test_helpers.cdc"
import "FlowCreditMarket"

access(all) let protocolAccount = Test.getAccount(0x0000000000000007)

access(all)
fun setup() {
    deployContracts()
}

// test get inital insurance funds
access(all) fun testGetInitialInsuranceFunds() {
    createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: defaultTokenIdentifier, beFailed: false)

    let actual= getInsuranceFundBalance()

    // newly created pool has insuranceFundBalance() == 0.
    Test.assertEqual(0.0, actual)
}