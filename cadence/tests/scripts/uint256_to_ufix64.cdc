import "TidalProtocolUtils"

access(all)
fun main(value: UInt256, decimals: UInt8): UFix64 {
    return TidalProtocolUtils.uint256ToUFix64(value, decimals: decimals)
}
