import Test
import "TidalProtocol"
import "DeFiActionsMathUtils"
import "FungibleToken"
import "MOET"
import "test_helpers.cdc"
import "MockYieldToken"

access(all) fun setup() {
    deployContracts()
}

access(all) fun snap(price: UFix64): TidalProtocol.TokenSnapshot {
    return TidalProtocol.TokenSnapshot(
        price: DeFiActionsMathUtils.toUInt128(price),
        credit: DeFiActionsMathUtils.e24,
        debit: DeFiActionsMathUtils.e24,
        risk: TidalProtocol.RiskParams(
            cf: DeFiActionsMathUtils.e24,
            bf: DeFiActionsMathUtils.e24,
            lb: DeFiActionsMathUtils.e24
        )
    )
}

access(all) let WAD: UInt128 = 1_000_000_000_000_000_000_000_000

access(all) fun test_calculateCloseoutBalance_handlesOtherTokens() {
    let tWithdraw = Type<@MOET.Vault>()
    let tColl = Type<@MockYieldToken.Vault>()

    let snaps: {Type: TidalProtocol.TokenSnapshot} = {}
    snaps[tWithdraw] = snap(price: 1.0)
    snaps[tColl] = snap(price: 2.0)

    let balances: {Type: TidalProtocol.InternalBalance} = {}
    balances[tWithdraw] = TidalProtocol.InternalBalance(direction: TidalProtocol.BalanceDirection.Debit,
        scaledBalance: DeFiActionsMathUtils.toUInt128(50.0))
    balances[tColl] = TidalProtocol.InternalBalance(direction: TidalProtocol.BalanceDirection.Credit,
        scaledBalance: DeFiActionsMathUtils.toUInt128(100.0))

    let view = TidalProtocol.PositionView(
        balances: balances,
        snapshots: snaps,
        def: tWithdraw,
        min: WAD,
        max: WAD
    )

    let topUpAvail: UInt128 = DeFiActionsMathUtils.toUInt128(60.0)

    let result = TidalProtocol.calculateCloseoutBalance(
        view: view,
        withdrawSnap: snaps[tWithdraw]!,
        topUpSnap: snaps[tWithdraw]!,
        topUpAvailable: topUpAvail
    )

    let expected = DeFiActionsMathUtils.toUInt128(210.0)
    Test.assertEqual(expected, result)
}
