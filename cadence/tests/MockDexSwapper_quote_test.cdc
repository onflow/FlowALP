import Test
import BlockchainHelpers
import "test_helpers.cdc"

import "MOET"

access(all)
fun test_mockdex_quote_math() {
    // Avoid redeploy collisions in CI by checking for existing pool
    let protocolAccount = Test.getAccount(0x0000000000000007)
    if !poolExists(address: protocolAccount.address) {
        deployContracts()
        createAndStorePool(signer: protocolAccount, defaultTokenIdentifier: Type<@MOET.Vault>().identifier, beFailed: false)
    }

    let signer = protocolAccount
    setupMoetVault(signer, beFailed: false)
    mintMoet(signer: signer, to: signer.address, amount: 10_000.0, beFailed: false)

    let txRes = _executeTransaction(
        "../transactions/mocks/dex/mockdex_quote_check.cdc",
        [1.5, 300.0, 200.0],
        signer
    )
    Test.expect(txRes, Test.beSucceeded())
}
