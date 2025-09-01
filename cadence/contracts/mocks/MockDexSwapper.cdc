import "Burner"
import "FungibleToken"

import "DeFiActions"
import "DeFiActionsUtils"

/// TEST-ONLY mock swapper that withdraws output from a user-provided Vault capability.
/// Do NOT use in production.
access(all) contract MockDexSwapper {

    access(all) struct BasicQuote : DeFiActions.Quote {
        access(all) let inType: Type
        access(all) let outType: Type
        access(all) let inAmount: UFix64
        access(all) let outAmount: UFix64
        init(inType: Type, outType: Type, inAmount: UFix64, outAmount: UFix64) {
            self.inType = inType
            self.outType = outType
            self.inAmount = inAmount
            self.outAmount = outAmount
        }
    }

    access(all) struct Swapper : DeFiActions.Swapper {
        access(self) let inVault: Type
        access(self) let outVault: Type
        access(self) let vaultSource: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>
        access(self) let priceRatio: UFix64 // out per unit in
        access(contract) var uniqueID: DeFiActions.UniqueIdentifier?

        init(inVault: Type, outVault: Type, vaultSource: Capability<auth(FungibleToken.Withdraw) &{FungibleToken.Vault}>, priceRatio: UFix64, uniqueID: DeFiActions.UniqueIdentifier?) {
            pre {
                inVault.getType().isSubtype(of: Type<@{FungibleToken.Vault}>()): "inVault must be a FungibleToken Vault"
                outVault.getType().isSubtype(of: Type<@{FungibleToken.Vault}>()): "outVault must be a FungibleToken Vault"
                vaultSource.check(): "Invalid vaultSource capability"
                priceRatio > 0.0: "Invalid price ratio"
            }
            self.inVault = inVault
            self.outVault = outVault
            self.vaultSource = vaultSource
            self.priceRatio = priceRatio
            self.uniqueID = uniqueID
        }

        access(all) view fun inType(): Type { return self.inVault }
        access(all) view fun outType(): Type { return self.outVault }

        access(all) fun quoteIn(forDesired: UFix64, reverse: Bool): {DeFiActions.Quote} {
            let inAmt = reverse ? forDesired / self.priceRatio : forDesired / self.priceRatio
            return BasicQuote(inType: reverse ? self.outType() : self.inType(), outType: reverse ? self.inType() : self.outType(), inAmount: inAmt, outAmount: forDesired)
        }

        access(all) fun quoteOut(forProvided: UFix64, reverse: Bool): {DeFiActions.Quote} {
            let outAmt = reverse ? forProvided / self.priceRatio : forProvided * self.priceRatio
            return BasicQuote(inType: reverse ? self.outType() : self.inType(), outType: reverse ? self.inType() : self.outType(), inAmount: forProvided, outAmount: outAmt)
        }

        access(all) fun swap(quote: {DeFiActions.Quote}?, inVault: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            pre { inVault.getType() == self.inType(): "Wrong in type" }
            let outAmt = (quote?.outAmount) ?? (inVault.balance * self.priceRatio)
            // burn seized input and withdraw from the provided source
            Burner.burn(<-inVault)
            let src = self.vaultSource.borrow() ?? panic("Invalid borrowed vault source")
            return <- src.withdraw(amount: outAmt)
        }

        access(all) fun swapBack(quote: {DeFiActions.Quote}?, residual: @{FungibleToken.Vault}): @{FungibleToken.Vault} {
            // Not needed in tests; burn residual and return empty inType vault
            Burner.burn(<-residual)
            return <- DeFiActionsUtils.getEmptyVault(self.inType())
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(type: self.getType(), id: self.id(), innerComponents: [])
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? { return self.uniqueID }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) { self.uniqueID = id }
    }
}


