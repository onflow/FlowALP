import Test
import BlockchainHelpers

import "MOET"
import "FlowALPv0"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// get_position_count script test
//
// Verifies that the get_position_count.cdc script correctly returns the total
// number of active positions in the Pool via the Pool.getPositionCount() getter.
// -----------------------------------------------------------------------------

access(all)
fun setup() {
    deployContracts()

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: 1.0)
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
}

// getPositionCount returns 0 when no positions have been opened
access(all)
fun test_position_count_is_zero_initially() {
    let res = _executeScript("../scripts/flow-alp/get_position_count.cdc", [])
    Test.expect(res, Test.beSucceeded())
    let count = res.returnValue as! Int
    Test.assertEqual(0, count)
}

// getPositionCount increments as positions are opened
access(all)
fun test_position_count_reflects_open_positions() {
    let user1 = Test.createAccount()
    let user2 = Test.createAccount()
    setupMoetVault(user1, beFailed: false)
    setupMoetVault(user2, beFailed: false)
    mintFlow(to: user1, amount: 1_000.0)
    mintFlow(to: user2, amount: 1_000.0)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user1)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user2)

    // Open first position
    let open1 = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user1
    )
    Test.expect(open1, Test.beSucceeded())

    let countAfterOne = (_executeScript("../scripts/flow-alp/get_position_count.cdc", []).returnValue as! Int?)!
    Test.assertEqual(1, countAfterOne)

    // Open second position
    let open2 = executeTransaction(
        "../transactions/flow-alp/position/create_position.cdc",
        [100.0, FLOW_VAULT_STORAGE_PATH, true],
        user2
    )
    Test.expect(open2, Test.beSucceeded())

    let countAfterTwo = (_executeScript("../scripts/flow-alp/get_position_count.cdc", []).returnValue as! Int?)!
    Test.assertEqual(2, countAfterTwo)
}
