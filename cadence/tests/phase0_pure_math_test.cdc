import Test
import "FlowALPv1"
import "FlowALPModels"
import "FungibleToken"
import "MOET"
import "test_helpers.cdc"
import "MockYieldToken"

access(all)
fun setup() {
    // Use the shared deploy routine so imported contracts (including FlowALPv1) are resolvable
    deployContracts()
}

// Helper to build a TokenSnapshot quickly
access(all)
fun snap(price: UFix128, creditIdx: UFix128, debitIdx: UFix128, cf: UFix128, bf: UFix128): FlowALPv1.TokenSnapshot {
    return FlowALPv1.TokenSnapshot(
        price: price,
        credit: creditIdx,
        debit: debitIdx,
        risk: FlowALPModels.RiskParamsImplv1(
            collateralFactor: cf,
            borrowFactor: bf,
        )
    )
}

access(all)
fun test_healthFactor_zeroBalances_returnsInfinite() {  // Renamed for clarity
    let balances: {Type: FlowALPModels.InternalBalance} = {}
    let snaps: {Type: FlowALPv1.TokenSnapshot} = {}
    let view = FlowALPv1.PositionView(
        balances: balances,
        snapshots: snaps,
        defaultToken: Type<@MOET.Vault>(),
        min: 1.1,
        max: 1.5
    )
    let h = FlowALPv1.healthFactor(view: view)
    Test.assertEqual(UFix128.max, h)  // Empty position (0/0) is safe with infinite health
}

// New test: Zero collateral with positive debt should return 0 health (unsafe)
access(all)
fun test_healthFactor_zeroCollateral_positiveDebt_returnsZero() {
    let tDebt = Type<@MockYieldToken.Vault>()

    let snapshots: {Type: FlowALPv1.TokenSnapshot} = {}
    snapshots[tDebt] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[tDebt] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Debit,
        scaledBalance: 50.0
    )

    let view = FlowALPv1.PositionView(
        balances: balances,
        snapshots: snapshots,
        defaultToken: tDebt,
        min: 1.1,
        max: 1.5
    )

    let h = FlowALPv1.healthFactor(view: view)
    Test.assertEqual(0.0 as UFix128, h)
}

access(all)
fun test_healthFactor_simpleCollateralAndDebt() {
    // Token types (use distinct contracts so keys differ)
    let tColl = Type<@MOET.Vault>()
    let tDebt = Type<@MockYieldToken.Vault>()

    // Build snapshots: indices at 1.0 so true == scaled
    let snapshots: {Type: FlowALPv1.TokenSnapshot} = {}
    snapshots[tColl] = snap(price: 2.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)
    snapshots[tDebt] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    // Balances: +100 collateral units, -50 debt units
    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[tColl] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Credit,
        scaledBalance: 100.0
    )
    balances[tDebt] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Debit,
        scaledBalance: 50.0
    )

    let view = FlowALPv1.PositionView(
        balances: balances,
        snapshots: snapshots,
        defaultToken: tColl,
        min: 1.1,
        max: 1.5
    )

    let h = FlowALPv1.healthFactor(view: view)
    // Expected health = (100 * 2 * 0.5) / (50 * 1 / 1.0) = 100 / 50 = 2.0
    Test.assertEqual(2.0 as UFix128, h)
}

access(all)
fun test_maxWithdraw_increasesDebtWhenNoCredit() {
    // Withdrawing MOET while having collateral in MockYieldToken
    let t = Type<@MOET.Vault>()
    let tColl = Type<@MockYieldToken.Vault>()
    let snapshots: {Type: FlowALPv1.TokenSnapshot} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.8, bf: 1.0)
    snapshots[tColl] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.8, bf: 1.0)

    // Balances: +100 collateral units on tColl, no entry for t (debt token)
    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[tColl] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Credit,
        scaledBalance: 100.0
    )

    let view = FlowALPv1.PositionView(
        balances: balances,
        snapshots: snapshots,
        defaultToken: t,
        min: 1.1,
        max: 1.5
    )

    let max = FlowALPv1.maxWithdraw(
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
    let snapshots: {Type: FlowALPv1.TokenSnapshot} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: 1.0, debitIdx: 1.0, cf: 0.5, bf: 1.0)

    let balances: {Type: FlowALPModels.InternalBalance} = {}
    balances[t] = FlowALPModels.InternalBalance(
        direction: FlowALPModels.BalanceDirection.Credit,
        scaledBalance: 100.0
    )

    let view = FlowALPv1.PositionView(
        balances: balances,
        snapshots: snapshots,
        defaultToken: t,
        min: 1.1,
        max: 1.5
    )

    let max = FlowALPv1.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: 1.3
    )
    // With no debt, health is infinite; withdrawal limited by credit balance (100)
    Test.assertEqual(100.0 as UFix128, max)
}


