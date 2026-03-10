import Test
import BlockchainHelpers
import "FlowALPv0"

import "test_helpers.cdc"

/// Tests the drawDown rebalancing path where sinkType != defaultToken.
///
/// Setup:
///   - Pool defaultToken = MOET
///   - MockYieldToken is the collateral token (Credit)
///   - drawDownSink accepts FLOW (not MOET) → creates FLOW Debit on position
///
/// When the position becomes overcollateralised (MockYieldToken price rises), the
/// rebalancer borrows FLOW from pool reserves — not mint MOET — and pushes it to the
/// user's FLOW vault. The position's FLOW debit grows (more FLOW borrowed) while the
/// pool's FLOW reserves shrink.

access(all) let MOCK_YIELD_TOKEN_IDENTIFIER = "A.0000000000000007.MockYieldToken.Vault"

access(all)
fun setup() {
    deployContracts()
}

access(all)
fun testDrawDownWithNonDefaultTokenSink() {
    let YT_PRICE: UFix64 = 1.0
    let FLOW_PRICE: UFix64 = 1.0

    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: FLOW_TOKEN_IDENTIFIER, price: FLOW_PRICE)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOET_TOKEN_IDENTIFIER, price: FLOW_PRICE)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOCK_YIELD_TOKEN_IDENTIFIER, price: YT_PRICE)

    // Pool: MOET as defaultToken; FLOW and MockYieldToken both supported as collateral
    createAndStorePool(signer: PROTOCOL_ACCOUNT, defaultTokenIdentifier: MOET_TOKEN_IDENTIFIER, beFailed: false)
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: FLOW_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )
    addSupportedTokenZeroRateCurve(
        signer: PROTOCOL_ACCOUNT,
        tokenTypeIdentifier: MOCK_YIELD_TOKEN_IDENTIFIER,
        collateralFactor: 0.8,
        borrowFactor: 1.0,
        depositRate: 1_000_000.0,
        depositCapacityCap: 1_000_000.0
    )

    // Protocol deposits a large FLOW reserve position so the pool has FLOW to lend.
    // pushToDrawDownSink=false: protocol does not draw down (its own sink is MOET).
    let RESERVE_AMOUNT: UFix64 = 10_000.0
    transferFlowTokens(to: PROTOCOL_ACCOUNT, amount: RESERVE_AMOUNT)
    setupMoetVault(PROTOCOL_ACCOUNT, beFailed: false)
    createPosition(signer: PROTOCOL_ACCOUNT, amount: RESERVE_AMOUNT, vaultStoragePath: FLOW_VAULT_STORAGE_PATH, pushToDrawDownSink: false)

    let flowReservesAtStart = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    log("FLOW in pool reserves after protocol deposit: \(flowReservesAtStart)")

    // User: MockYieldToken collateral, FLOW drawDownSink.
    // pushToDrawDownSink=true — pool immediately draws FLOW from reserves and pushes
    // to the user's FLOW vault, establishing an initial FLOW Debit on the position.
    let user = Test.createAccount()
    let COLLATERAL: UFix64 = 1_000.0
    transferFlowTokens(to: user, amount: 100.0)
    setupMockYieldTokenVault(user, beFailed: false)
    mintMockYieldToken(signer: PROTOCOL_ACCOUNT, to: user.address, amount: COLLATERAL, beFailed: false)
    grantBetaPoolParticipantAccess(PROTOCOL_ACCOUNT, user)

    let flowBeforeOpen = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!

    let openRes = _executeTransaction(
        "./transactions/flow-alp/position/create_position_yt_collateral_flow_sink.cdc",
        [COLLATERAL, true],   // pushToDrawDownSink=true: pool borrows FLOW immediately
        user
    )
    Test.expect(openRes, Test.beSucceeded())

    // pid=0: protocol reserve position; pid=1: user's YT-collateral position
    let userPid: UInt64 = 1

    let flowAfterOpen = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    let healthAfterOpen = getPositionHealth(pid: userPid, beFailed: false)
    let flowReservesAfterOpen = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)

    log("User FLOW before open: \(flowBeforeOpen)")
    log("User FLOW after open (initial drawDown fired): \(flowAfterOpen)")
    log("Health after open (should ≈ TARGET_HEALTH): \(healthAfterOpen)")
    log("FLOW reserves after open: \(flowReservesAfterOpen)")

    // Initial drawDown fired: user received FLOW, health is at targetHealth, reserves decreased
    Test.assert(flowAfterOpen > flowBeforeOpen,
        message: "Expected initial drawDown to push FLOW to user, got \(flowAfterOpen) (was \(flowBeforeOpen))")
    Test.assert(equalAmounts128(a: healthAfterOpen, b: INT_TARGET_HEALTH, tolerance: 0.00000001),
        message: "Expected health ≈ TARGET_HEALTH (\(INT_TARGET_HEALTH)) after open, got \(healthAfterOpen)")
    Test.assert(flowReservesAfterOpen < flowReservesAtStart,
        message: "Expected FLOW reserves to decrease after initial drawDown")

    let detailsBefore = getPositionDetails(pid: userPid, beFailed: false)
    let flowDebitBefore = getDebitBalanceForType(
        details: detailsBefore,
        vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!
    )
    log("FLOW debit after open: \(flowDebitBefore)")

    // MockYieldToken price doubles → position becomes overcollateralised (health > MAX_HEALTH)
    setMockOraclePrice(signer: PROTOCOL_ACCOUNT, forTokenIdentifier: MOCK_YIELD_TOKEN_IDENTIFIER, price: YT_PRICE * 2.0)

    let healthAfterPriceChange = getPositionHealth(pid: userPid, beFailed: false)
    log("Health after YT price doubles: \(healthAfterPriceChange)")
    Test.assert(healthAfterPriceChange >= INT_MAX_HEALTH,
        message: "Expected health >= MAX_HEALTH (\(INT_MAX_HEALTH)) after price doubling, got \(healthAfterPriceChange)")

    // Rebalance — drawDown path fires with sinkType=FLOW, defaultToken=MOET
    rebalancePosition(signer: PROTOCOL_ACCOUNT, pid: userPid, force: true, beFailed: false)

    let healthAfterRebalance = getPositionHealth(pid: userPid, beFailed: false)
    let flowAfterRebalance = getBalance(address: user.address, vaultPublicPath: /public/flowTokenReceiver)!
    let flowReservesAfterRebalance = getReserveBalance(vaultIdentifier: FLOW_TOKEN_IDENTIFIER)
    let flowDebitAfter = getDebitBalanceForType(
        details: getPositionDetails(pid: userPid, beFailed: false),
        vaultType: CompositeType(FLOW_TOKEN_IDENTIFIER)!
    )

    log("Health after rebalance (should ≈ TARGET_HEALTH): \(healthAfterRebalance)")
    log("User FLOW after rebalance: \(flowAfterRebalance)")
    log("FLOW reserves after rebalance: \(flowReservesAfterRebalance)")
    log("FLOW debit after rebalance: \(flowDebitAfter)")

    // Health pulled back to targetHealth
    Test.assert(healthAfterRebalance < healthAfterPriceChange,
        message: "Expected health to decrease after drawDown rebalance")
    Test.assert(equalAmounts128(a: healthAfterRebalance, b: INT_TARGET_HEALTH, tolerance: 0.00000001),
        message: "Expected health restored to TARGET_HEALTH (\(INT_TARGET_HEALTH)), got \(healthAfterRebalance)")

    // User received more FLOW (pool pushed sinkType=FLOW from reserves)
    Test.assert(flowAfterRebalance > flowAfterOpen,
        message: "Expected user FLOW to increase after rebalance drawDown, got \(flowAfterRebalance) (was \(flowAfterOpen))")

    // Pool FLOW reserves decreased by the drawn amount
    Test.assert(flowReservesAfterRebalance < flowReservesAfterOpen,
        message: "Expected FLOW reserves to decrease after drawDown, got \(flowReservesAfterRebalance) (was \(flowReservesAfterOpen))")

    // Position's FLOW debit grew — pool borrowed more FLOW on behalf of the position
    Test.assert(flowDebitAfter > flowDebitBefore,
        message: "Expected FLOW debit to increase after drawDown, got \(flowDebitAfter) (was \(flowDebitBefore))")

    // Drawn amount should match debit increase and reserve decrease (within rounding tolerance)
    let drawnAmount = flowAfterRebalance - flowAfterOpen
    let debitIncrease = flowDebitAfter - flowDebitBefore
    let reserveDecrease = flowReservesAfterOpen - flowReservesAfterRebalance
    log("FLOW drawn to user in rebalance: \(drawnAmount)")
    log("FLOW debit increase: \(debitIncrease)")
    log("FLOW reserve decrease: \(reserveDecrease)")
    Test.assert(equalAmounts(a: drawnAmount, b: debitIncrease, tolerance: 0.01),
        message: "Expected drawn amount (\(drawnAmount)) ≈ debit increase (\(debitIncrease))")
    Test.assert(equalAmounts(a: drawnAmount, b: reserveDecrease, tolerance: 0.01),
        message: "Expected drawn amount (\(drawnAmount)) ≈ reserve decrease (\(reserveDecrease))")
}
