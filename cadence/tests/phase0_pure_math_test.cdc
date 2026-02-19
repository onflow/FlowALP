import Test
<<<<<<< HEAD
import "FlowALPv1"
import "FlowALPModels"
=======
import "FlowALPv0"
>>>>>>> main
import "FungibleToken"
import "MOET"
import "test_helpers.cdc"
import "MockYieldToken"

access(all)
fun setup() {
    // Use the shared deploy routine so imported contracts (including FlowALPv0) are resolvable
    deployContracts()
}

// Helper to build a TokenSnapshot quickly
access(all)
<<<<<<< HEAD
fun snap(price: UFix128, creditIdx: UFix128, debitIdx: UFix128, cf: UFix128, bf: UFix128): {FlowALPModels.TokenSnapshot} {
    return FlowALPModels.TokenSnapshotImplv1(
        price: price,
        credit: creditIdx,
        debit: debitIdx,
        risk: FlowALPModels.RiskParamsImplv1(
=======
fun snap(price: UFix128, creditIdx: UFix128, debitIdx: UFix128, cf: UFix128, bf: UFix128): FlowALPv0.TokenSnapshot {
    return FlowALPv0.TokenSnapshot(
        price: price,
        credit: creditIdx,
        debit: debitIdx,
        risk: FlowALPv0.RiskParams(
>>>>>>> main
            collateralFactor: cf,
            borrowFactor: bf,
        )
    )
}

access(all)
fun test_healthFactor_zeroBalances_returnsInfinite() {  // Renamed for clarity
<<<<<<< HEAD
    let balances: {Type: FlowALPModels.InternalBalance} = {}
    let snaps: {Type: {FlowALPModels.TokenSnapshot}} = {}
    let view = FlowALPModels.PositionView(
=======
    let balances: {Type: FlowALPv0.InternalBalance} = {}
    let snaps: {Type: FlowALPv0.TokenSnapshot} = {}
    let view = FlowALPv0.PositionView(
>>>>>>> main
        balances: balances,
        snapshots: snaps,
        defaultToken: Type<@MOET.Vault>(),
        min: 1.1,
        max: 1.5
    )
<<<<<<< HEAD
    let h = FlowALPModels.healthFactor(view: view)
=======
    let h = FlowALPv0.healthFactor(view: view)
>>>>>>> main
    Test.assertEqual(UFix128.max, h)  // Empty position (0/0) is safe with infinite health
}

// New test: Zero collateral with positive debt should return 0 health (unsafe)
access(all)
fun test_healthFactor_zeroCollateral_positiveDebt_returnsZero() {
    let tDebt = Type<@MockYieldToken.Vault>()

<<<<<<< HEAD
    let snapshots: {Type: {FlowALPModels.TokenSnapshot}} = {}
    snapshots[tDebt] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[tDebt] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Debit,
        scaledBalance: 50.0
    )

    let view = FlowALPModels.PositionView(
=======
    let snapshots: {Type: FlowALPv0.TokenSnapshot} = {}
    snapshots[tDebt] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    let balances: {Type: FlowALPv0.InternalBalance} = {}
    balances[tDebt] = FlowALPv0.InternalBalance(
        direction: FlowALPv0.BalanceDirection.Debit,
        scaledBalance: 50.0
    )

    let view = FlowALPv0.PositionView(
>>>>>>> main
        balances: balances,
        snapshots: snapshots,
        defaultToken: tDebt,
        min: 1.1,
        max: 1.5
    )

<<<<<<< HEAD
    let h = FlowALPModels.healthFactor(view: view)
=======
    let h = FlowALPv0.healthFactor(view: view)
>>>>>>> main
    Test.assertEqual(0.0 as UFix128, h)
}

access(all)
fun test_healthFactor_simpleCollateralAndDebt() {
    // Token types (use distinct contracts so keys differ)
    let tColl = Type<@MOET.Vault>()
    let tDebt = Type<@MockYieldToken.Vault>()

    // Build snapshots: indices at 1.0 so true == scaled
<<<<<<< HEAD
    let snapshots: {Type: {FlowALPModels.TokenSnapshot}} = {}
=======
    let snapshots: {Type: FlowALPv0.TokenSnapshot} = {}
>>>>>>> main
    snapshots[tColl] = snap(price: 2.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)
    snapshots[tDebt] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    // Balances: +100 collateral units, -50 debt units
<<<<<<< HEAD
    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[tColl] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Credit,
        scaledBalance: 100.0
    )
    balances[tDebt] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Debit,
        scaledBalance: 50.0
    )

    let view = FlowALPModels.PositionView(
=======
    let balances: {Type: FlowALPv0.InternalBalance} = {}
    balances[tColl] = FlowALPv0.InternalBalance(
        direction: FlowALPv0.BalanceDirection.Credit,
        scaledBalance: 100.0
    )
    balances[tDebt] = FlowALPv0.InternalBalance(
        direction: FlowALPv0.BalanceDirection.Debit,
        scaledBalance: 50.0
    )

    let view = FlowALPv0.PositionView(
>>>>>>> main
        balances: balances,
        snapshots: snapshots,
        defaultToken: tColl,
        min: 1.1,
        max: 1.5
    )

<<<<<<< HEAD
    let h = FlowALPModels.healthFactor(view: view)
=======
    let h = FlowALPv0.healthFactor(view: view)
>>>>>>> main
    // Expected health = (100 * 2 * 0.5) / (50 * 1 / 1.0) = 100 / 50 = 2.0
    Test.assertEqual(2.0 as UFix128, h)
}

access(all)
fun test_maxWithdraw_increasesDebtWhenNoCredit() {
    // Withdrawing MOET while having collateral in MockYieldToken
    let t = Type<@MOET.Vault>()
    let tColl = Type<@MockYieldToken.Vault>()
<<<<<<< HEAD
    let snapshots: {Type: {FlowALPModels.TokenSnapshot}} = {}
=======
    let snapshots: {Type: FlowALPv0.TokenSnapshot} = {}
>>>>>>> main
    snapshots[t] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.8, bf: 1.0)
    snapshots[tColl] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.8, bf: 1.0)

    // Balances: +100 collateral units on tColl, no entry for t (debt token)
<<<<<<< HEAD
    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[tColl] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Credit,
        scaledBalance: 100.0
    )

    let view = FlowALPModels.PositionView(
=======
    let balances: {Type: FlowALPv0.InternalBalance} = {}
    balances[tColl] = FlowALPv0.InternalBalance(
        direction: FlowALPv0.BalanceDirection.Credit,
        scaledBalance: 100.0
    )

    let view = FlowALPv0.PositionView(
>>>>>>> main
        balances: balances,
        snapshots: snapshots,
        defaultToken: t,
        min: 1.1,
        max: 1.5
    )

    let max = FlowALPv0.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: 1.3
    )
    // Expected tokens = effColl / targetHealth (bf=1, price=1)
    // effColl = 100 * 1 * 0.8 = 80
    let effColl: UFix128 = 80.0
    let expected = effColl / 1.3
    Test.assert(
        ufix128EqualWithinVariance(expected, max),
        message: "maxWithdraw debt increase mismatch"
    )
}

access(all)
fun test_maxWithdraw_fromCollateralLimitedByHealth() {
    // Withdrawing from a credit position
    let t = Type<@MOET.Vault>()
<<<<<<< HEAD
    let snapshots: {Type: {FlowALPModels.TokenSnapshot}} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[t] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Credit,
        scaledBalance: 100.0
    )

    let view = FlowALPModels.PositionView(
=======
    let snapshots: {Type: FlowALPv0.TokenSnapshot} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    let balances: {Type: FlowALPv0.InternalBalance} = {}
    balances[t] = FlowALPv0.InternalBalance(
        direction: FlowALPv0.BalanceDirection.Credit,
        scaledBalance: 100.0
    )

    let view = FlowALPv0.PositionView(
>>>>>>> main
        balances: balances,
        snapshots: snapshots,
        defaultToken: t,
        min: 1.1,
        max: 1.5
    )

    let max = FlowALPv0.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: 1.3
    )
    // With no debt, health is infinite; withdrawal limited by credit balance (100)
    Test.assertEqual(100.0 as UFix128, max)
}


