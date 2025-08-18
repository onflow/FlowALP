import Test
import "TidalProtocol"
import "TidalProtocolUtils"
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
fun snap(price: UFix64, creditIdx: UInt256, debitIdx: UInt256, cf: UFix64, bf: UFix64): TidalProtocol.TokenSnapshot {
    return TidalProtocol.TokenSnapshot(
        price: TidalProtocolUtils.ufix64ToUInt256(price, decimals: TidalProtocolUtils.decimals),
        credit: creditIdx,
        debit: debitIdx,
        risk: TidalProtocol.RiskParams(
            cf: TidalProtocolUtils.ufix64ToUInt256(cf, decimals: TidalProtocolUtils.decimals),
            bf: TidalProtocolUtils.ufix64ToUInt256(bf, decimals: TidalProtocolUtils.decimals),
            lb: TidalProtocolUtils.e18
        )
    )
}

// e18 constant alias
access(all) let WAD: UInt256 = 1_000_000_000_000_000_000

access(all)
fun test_healthFactor_zeroBalances_returnsZero() {
    let balances: {Type: TidalProtocol.InternalBalance} = {}
    let snaps: {Type: TidalProtocol.TokenSnapshot} = {}
    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snaps,
        def: Type<@MOET.Vault>(),
        min: 1_100_000_000_000_000_000,
        max: 1_500_000_000_000_000_000
    )
    let h = TidalProtocol.healthFactor(view: view)
    Test.assertEqual(UInt256(0), h)
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
        scaledBalance: TidalProtocolUtils.ufix64ToUInt256(100.0, decimals: TidalProtocolUtils.decimals))
    balances[tDebt] = TidalProtocol.InternalBalance(direction: TidalProtocol.BalanceDirection.Debit,
        scaledBalance: TidalProtocolUtils.ufix64ToUInt256(50.0, decimals: TidalProtocolUtils.decimals))

    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: tColl,
        min: 1_100_000_000_000_000_000,
        max: 1_500_000_000_000_000_000
    )

    // Expected health = (100 * 2 * 0.5) / (50 * 1 / 1.0) = 100 / 50 = 2.0
    let expected = TidalProtocolUtils.ufix64ToUInt256(2.0, decimals: TidalProtocolUtils.decimals)
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
        scaledBalance: TidalProtocolUtils.ufix64ToUInt256(100.0, decimals: TidalProtocolUtils.decimals))

    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: t,
        min: 1_100_000_000_000_000_000,
        max: 1_500_000_000_000_000_000
    )

    let max = TidalProtocol.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: 1_300_000_000_000_000_000
    )
    // Expected tokens = effColl / targetHealth (bf=1, price=1), computed in 18-decimal UInt256 math
    // effColl = 100 * 1 * 0.8 = 80 (as 80e18)
    let effColl = TidalProtocolUtils.ufix64ToUInt256(80.0, decimals: TidalProtocolUtils.decimals)
    let expected = TidalProtocolUtils.div(effColl, 1_300_000_000_000_000_000)
    log("max (uint256): ".concat(max.toString()))
    log("expected (uint256): ".concat(expected.toString()))
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
        scaledBalance: TidalProtocolUtils.ufix64ToUInt256(100.0, decimals: TidalProtocolUtils.decimals))

    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snapshots,
        def: t,
        min: 1_100_000_000_000_000_000,
        max: 1_500_000_000_000_000_000
    )

    let max = TidalProtocol.maxWithdraw(
        view: view,
        withdrawSnap: snapshots[t]!,
        withdrawBal: view.balances[t],
        targetHealth: 1_300_000_000_000_000_000
    )
    // With no debt, health is infinite; withdrawal limited by credit balance (100)
    let expected = TidalProtocolUtils.ufix64ToUInt256(100.0, decimals: TidalProtocolUtils.decimals)
    Test.assertEqual(expected, max)
}


