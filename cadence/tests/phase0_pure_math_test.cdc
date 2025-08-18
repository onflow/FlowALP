import Test
import "TidalProtocol"
import "DeFiActionsMathUtils"
import "FungibleToken"
import "MOET"
import "test_helpers.cdc"
import "MockYieldToken"

access(all)
fun setup() {
    // Use the shared deploy routine so imported contracts (including TidalProtocol) are resolvable
    deployContracts()
}

// Helper to build a TokenSnapshot quickly
access(all)
fun snap(price: UFix64, creditIdx: UInt128, debitIdx: UInt128, cf: UFix64, bf: UFix64): TidalProtocol.TokenSnapshot {
    return TidalProtocol.TokenSnapshot(
        price: DeFiActionsMathUtils.toUInt128(price),
        credit: creditIdx,
        debit: debitIdx,
        risk: TidalProtocol.RiskParams(
            cf: DeFiActionsMathUtils.toUInt128(cf),
            bf: DeFiActionsMathUtils.toUInt128(bf),
            lb: DeFiActionsMathUtils.e24
        )
    )
}

// e24 constant alias
access(all) let WAD: UInt128 = 1_000_000_000_000_000_000_000_000

access(all)
fun test_healthFactor_zeroBalances_returnsZero() {
    let balances: {Type: TidalProtocol.InternalBalance} = {}
    let snaps: {Type: TidalProtocol.TokenSnapshot} = {}
    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snaps,
        def: Type<@MOET.Vault>(),
        min: DeFiActionsMathUtils.toUInt128(1.1),
        max: DeFiActionsMathUtils.toUInt128(1.5)
    )
    let h = TidalProtocol.healthFactor(view: view)
    Test.assertEqual(UInt128(0), h)
}

access(all)
fun test_healthFactor_simpleCollateralAndDebt() {
    // Token types (use distinct contracts so keys differ)
    let tColl = Type<@MOET.Vault>()
    let tDebt = Type<@MockYieldToken.Vault>()

    // Build snapshots: indices at 1.0 so true == scaled
    let snapshots: {Type: TidalProtocol.TokenSnapshot} = {}
    snapshots[tColl] = snap(price: 2.0, creditIdx: WAD, debitIdx: WAD, cf: 0.5, bf: 1.0)
    snapshots[tDebt] = snap(price: 1.0, creditIdx: WAD, debitIdx: WAD, cf: 0.5, bf: 1.0)

    // Balances: +100 collateral units, -50 debt units
    let balances: {Type: TidalProtocol.InternalBalance} = {}
    balances[tColl] = TidalProtocol.InternalBalance(direction: TidalProtocol.BalanceDirection.Credit,
        scaledBalance: DeFiActionsMathUtils.toUInt128(100.0))
    balances[tDebt] = TidalProtocol.InternalBalance(direction: TidalProtocol.BalanceDirection.Debit,
        scaledBalance: DeFiActionsMathUtils.toUInt128(50.0))

    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: tColl,
        min: DeFiActionsMathUtils.toUInt128(1.1),
        max: DeFiActionsMathUtils.toUInt128(1.5)
    )

    // Expected health = (100 * 2 * 0.5) / (50 * 1 / 1.0) = 100 / 50 = 2.0
    let expected = DeFiActionsMathUtils.toUInt128(2.0)
    let h = TidalProtocol.healthFactor(view: view)
    Test.assertEqual(expected, h)
}

access(all)
fun test_maxWithdraw_increasesDebtWhenNoCredit() {
    // Withdrawing MOET while having collateral in MockYieldToken
    let t = Type<@MOET.Vault>()
    let tColl = Type<@MockYieldToken.Vault>()
    let snapshots: {Type: TidalProtocol.TokenSnapshot} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: WAD, debitIdx: WAD, cf: 0.8, bf: 1.0)
    snapshots[tColl] = snap(price: 1.0, creditIdx: WAD, debitIdx: WAD, cf: 0.8, bf: 1.0)

    // Balances: +100 collateral units on tColl, no entry for t (debt token)
    let balances: {Type: TidalProtocol.InternalBalance} = {}
    balances[tColl] = TidalProtocol.InternalBalance(direction: TidalProtocol.BalanceDirection.Credit,
        scaledBalance: DeFiActionsMathUtils.toUInt128(100.0))

    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: t,
        min: DeFiActionsMathUtils.toUInt128(1.1),
        max: DeFiActionsMathUtils.toUInt128(1.5)
    )

    let max = TidalProtocol.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: DeFiActionsMathUtils.toUInt128(1.3)
    )
    // Expected tokens = effColl / targetHealth (bf=1, price=1), computed in 24-decimal UInt128 math
    // effColl = 100 * 1 * 0.8 = 80 (as 80e24)
    let effColl = DeFiActionsMathUtils.toUInt128(80.0)
    let expected = DeFiActionsMathUtils.div(effColl, DeFiActionsMathUtils.toUInt128(1.3))
    log("max (uint128): ".concat(max.toString()))
    log("expected (uint128): ".concat(expected.toString()))
    Test.assert(uintEqualWithinVariance(expected, max), message: "maxWithdraw debt increase mismatch")
}

access(all)
fun test_maxWithdraw_fromCollateralLimitedByHealth() {
    // Withdrawing from a credit position
    let t = Type<@MOET.Vault>()
    let snapshots: {Type: TidalProtocol.TokenSnapshot} = {}
    snapshots[t] = snap(price: 1.0, creditIdx: WAD, debitIdx: WAD, cf: 0.5, bf: 1.0)

    let balances: {Type: TidalProtocol.InternalBalance} = {}
    balances[t] = TidalProtocol.InternalBalance(direction: TidalProtocol.BalanceDirection.Credit,
        scaledBalance: DeFiActionsMathUtils.toUInt128(100.0))

    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: t,
        min: DeFiActionsMathUtils.toUInt128(1.1),
        max: DeFiActionsMathUtils.toUInt128(1.5)
    )

    let max = TidalProtocol.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: DeFiActionsMathUtils.toUInt128(1.3)
    )
    // With no debt, health is infinite; withdrawal limited by credit balance (100)
    let expected = DeFiActionsMathUtils.toUInt128(100.0)
    Test.assertEqual(expected, max)
}


