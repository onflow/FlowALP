import TidalProtocol from "TidalProtocol"

access(all) fun main(effectiveCollateral: UFix64, effectiveDebt: UFix64): UFix64 {
    return TidalProtocol.healthComputation(
        effectiveCollateral: effectiveCollateral,
        effectiveDebt: effectiveDebt
    )
} 