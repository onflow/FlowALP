import Test
import "FlowALP"
import "FungibleToken"
import "MOET"
import "test_helpers.cdc"
import "MockYieldToken"

access(all)
fun setup() {
    // Use the shared deploy routine so imported contracts (including FlowALP) are resolvable
    deployContracts()
}

// Helper to build a TokenSnapshot quickly
access(all)
fun snap(price: UFix64, creditIdx: UFix128, debitIdx: UFix128, cf: UFix64, bf: UFix64): FlowALP.TokenSnapshot {
    return FlowALP.TokenSnapshot(
        price: UFix128(price),
        credit: creditIdx,
        debit: debitIdx,
        risk: FlowALP.RiskParams(
            cf: UFix128(cf),
            bf: UFix128(bf),
            lb: UFix128(0.05)
        )
    )
}
access(all) let ONE: UFix128 = 1.0 as UFix128

access(all)
fun test_healthFactor_zeroBalances_returnsInfinite() {  // Renamed for clarity
    let balances: {Type: FlowALP.InternalBalance} = {}
    let snaps: {Type: FlowALP.TokenSnapshot} = {}
    let view = FlowALP.PositionView(
        balances: balances,
        snapshots: snaps,
        def: Type<@MOET.Vault>(),
        min: 1.1 as UFix128,
        max: 1.5 as UFix128
    )
    let h = FlowALP.healthFactor(view: view)
    Test.assertEqual(UFix128.max, h)  // Empty position (0/0) is safe with infinite health
}

// New test: Zero collateral with positive debt should return 0 health (unsafe)
access(all)
fun test_healthFactor_zeroCollateral_positiveDebt_returnsZero() {
    let tDebt = Type<@MockYieldToken.Vault>()
    
    let snapshots: {Type: FlowALP.TokenSnapshot} = {}
    snapshots[tDebt] = snap(price: 1.0, creditIdx: ONE, debitIdx: ONE, cf: 0.5, bf: 1.0)
    
    let balances: {Type: FlowALP.InternalBalance} = {}
    balances[tDebt] = FlowALP.InternalBalance(direction: FlowALP.BalanceDirection.Debit,
        scaledBalance: 50.0 as UFix128)
    
    let view = FlowALP.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: tDebt,
        min: 1.1 as UFix128,
        max: 1.5 as UFix128
    )
    
    let h = FlowALP.healthFactor(view: view)
    Test.assertEqual(0.0 as UFix128, h)
}

access(all)
fun test_healthFactor_simpleCollateralAndDebt() {
    // Token types (use distinct contracts so keys differ)
    let tColl = Type<@MOET.Vault>()
    let tDebt = Type<@MockYieldToken.Vault>()

    // Build snapshots: indices at 1.0 so true == scaled
    let snapshots: {Type: FlowALP.TokenSnapshot} = {}
    snapshots[tColl] = snap(price: 2.0, creditIdx: ONE, debitIdx: ONE, cf: 0.5, bf: 1.0)
    snapshots[tDebt] = snap(price: 1.0, creditIdx: ONE, debitIdx: ONE, cf: 0.5, bf: 1.0)

    // Balances: +100 collateral units, -50 debt units
    let balances: {Type: FlowALP.InternalBalance} = {}
    balances[tColl] = FlowALP.InternalBalance(direction: FlowALP.BalanceDirection.Credit,
        scaledBalance: 100.0 as UFix128)
    balances[tDebt] = FlowALP.InternalBalance(direction: FlowALP.BalanceDirection.Debit,
        scaledBalance: 50.0 as UFix128)

    let view = FlowALP.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: tColl,
        min: 1.1 as UFix128,
        max: 1.5 as UFix128
    )

    // Expected health = (100 * 2 * 0.5) / (50 * 1 / 1.0) = 100 / 50 = 2.0
    let expected = 2.0 as UFix128
    let h = FlowALP.healthFactor(view: view)
    Test.assertEqual(expected, h)
}

access(all)
fun test_maxWithdraw_increasesDebtWhenNoCredit() {
    // Withdrawing MOET while having collateral in MockYieldToken
    let t = Type<@MOET.Vault>()
    let tColl = Type<@MockYieldToken.Vault>()
    let snapshots: {Type: FlowALP.TokenSnapshot} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: ONE, debitIdx: ONE, cf: 0.8, bf: 1.0)
    snapshots[tColl] = snap(price: 1.0, creditIdx: ONE, debitIdx: ONE, cf: 0.8, bf: 1.0)

    // Balances: +100 collateral units on tColl, no entry for t (debt token)
    let balances: {Type: FlowALP.InternalBalance} = {}
    balances[tColl] = FlowALP.InternalBalance(direction: FlowALP.BalanceDirection.Credit,
        scaledBalance: 100.0 as UFix128)

    let view = FlowALP.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: t,
        min: 1.1 as UFix128,
        max: 1.5 as UFix128
    )

    let max = FlowALP.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: 1.3 as UFix128
    )
    // Expected tokens = effColl / targetHealth (bf=1, price=1)
    // effColl = 100 * 1 * 0.8 = 80
    let effColl = 80.0 as UFix128
    let expected = effColl / (1.3 as UFix128)
    Test.assert(ufix128EqualWithinVariance(expected, max), message: "maxWithdraw debt increase mismatch")
}

access(all)
fun test_maxWithdraw_fromCollateralLimitedByHealth() {
    // Withdrawing from a credit position
    let t = Type<@MOET.Vault>()
    let snapshots: {Type: FlowALP.TokenSnapshot} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: ONE, debitIdx: ONE, cf: 0.5, bf: 1.0)

    let balances: {Type: FlowALP.InternalBalance} = {}
    balances[t] = FlowALP.InternalBalance(direction: FlowALP.BalanceDirection.Credit,
        scaledBalance: 100.0 as UFix128)

    let view = FlowALP.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: t,
        min: 1.1 as UFix128,
        max: 1.5 as UFix128
    )

    let max = FlowALP.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: 1.3 as UFix128
    )
    // With no debt, health is infinite; withdrawal limited by credit balance (100)
    let expected = 100.0 as UFix128
    Test.assertEqual(expected, max)
}


