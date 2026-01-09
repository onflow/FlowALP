import "Burner"
import "FungibleToken"

import "DeFiActions"
import "DeFiActionsUtils"
import "FlowCreditMarket"

/// TEST-ONLY mock swapper that withdraws output from a user-provided Vault capability.
/// Do NOT use in production.
access(all) contract MockDexSwapper {

    /// inType -> outType -> Swapper
    access(contract) let swappers: {Type: {Type: Swapper}}

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
                inVault.isSubtype(of: Type<@{FungibleToken.Vault}>()): "inVault must be a FungibleToken Vault"
                outVault.isSubtype(of: Type<@{FungibleToken.Vault}>()): "outVault must be a FungibleToken Vault"
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
            let inAmt = reverse ? forDesired * self.priceRatio : forDesired / self.priceRatio
            return BasicQuote(
                inType: reverse ? self.outType() : self.inType(),
                outType: reverse ? self.inType() : self.outType(),
                inAmount: inAmt,
                outAmount: forDesired
            )
        }

        access(all) fun quoteOut(forProvided: UFix64, reverse: Bool): {DeFiActions.Quote} {
            let outAmt = reverse ? forProvided / self.priceRatio : forProvided * self.priceRatio
            return BasicQuote(
                inType: reverse ? self.outType() : self.inType(),
                outType: reverse ? self.inType() : self.outType(),
                inAmount: forProvided,
                outAmount: outAmt
            )
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
            // Not needed in tests; burn residual and panic to surface misuse
            Burner.burn(<-residual)
            panic("MockSwapper.swapBack() not implemented")
        }

        access(all) fun getComponentInfo(): DeFiActions.ComponentInfo {
            return DeFiActions.ComponentInfo(type: self.getType(), id: self.id(), innerComponents: [])
        }
        access(contract) view fun copyID(): DeFiActions.UniqueIdentifier? { return self.uniqueID }
        access(contract) fun setID(_ id: DeFiActions.UniqueIdentifier?) { self.uniqueID = id }
    }

    /// Adds the given swapper to the contract, overwriting any previously added swapper with the same in/out type.
    /// After addition, will be returned by SwapperProvider.getSwapper.
    access(all) fun addSwapper(swapper: Swapper) {
        if let swappersByInType = self.swappers[swapper.inType()] {
            swappersByInType[swapper.outType()] = swapper
            self.swappers[swapper.inType()] = swappersByInType
        } else {
            self.swappers[swapper.inType()] = {swapper.outType(): swapper}
        }
    }

    /// Provides access to the set of swappers stored in this mock contract.
    /// Tests can instantiate a pool with an instance of SwapperProvider,
    /// then control the DEX behaviour with addSwapper.
    access(all) struct SwapperProvider : FlowCreditMarket.SwapperProvider {
        access(all) fun getSwapper(inType: Type, outType: Type): {DeFiActions.Swapper}? {
            if let swappersForInType = MockDexSwapper.swappers[inType] {  
                return swappersForInType[outType]
            }
            return nil
        }
    }

    init() {
        self.swappers = {}
    }
}


