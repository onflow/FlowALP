import "FungibleToken"
import "MockDexSwapper"
import "MOET"

/// TEST-ONLY: Assert MockDexSwapper quote math for forward and reverse directions
/// priceRatio: out per unit in
/// forDesired: desired out amount for quoteIn
/// forProvided: provided in amount for quoteOut
transaction(priceRatio: UFix64, forDesired: UFix64, forProvided: UFix64) {
    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, PublishCapability) &Account) {
        // Issue a capability to the signer's MOET vault (must be set up by the test before calling)
        let sourceCap = signer.capabilities.storage.issue<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>(MOET.VaultStoragePath)

        // Use MOET both sides to avoid external deps; math is independent of token
        let swapper = MockDexSwapper.Swapper(
            inVault: Type<@MOET.Vault>(),
            outVault: Type<@MOET.Vault>(),
            vaultSource: sourceCap,
            priceRatio: priceRatio,
            uniqueID: nil
        )

        let qOutF = swapper.quoteOut(forProvided: forProvided, reverse: false)
        let qOutR = swapper.quoteOut(forProvided: forProvided, reverse: true)
        let qInF = swapper.quoteIn(forDesired: forDesired, reverse: false)
        let qInR = swapper.quoteIn(forDesired: forDesired, reverse: true)

        let eps: UFix64 = 0.00000001
        fun approxEq(_ a: UFix64, _ b: UFix64, _ e: UFix64): Bool {
            let d = a > b ? a - b : b - a
            return d <= e
        }

        // Validate quoteOut math
        assert(approxEq(qOutF.outAmount, forProvided * priceRatio, eps), message: "quoteOut forward mismatch")
        assert(approxEq(qOutR.outAmount, forProvided / priceRatio, eps), message: "quoteOut reverse mismatch")

        // Validate quoteIn math
        assert(approxEq(qInF.inAmount, forDesired / priceRatio, eps), message: "quoteIn forward mismatch")
        assert(approxEq(qInR.inAmount, forDesired * priceRatio, eps), message: "quoteIn reverse mismatch")
    }
}


