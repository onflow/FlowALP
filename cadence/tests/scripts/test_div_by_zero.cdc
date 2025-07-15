import "TidalProtocolUtils"

access(all)
fun main(x: UInt256, y: UInt256): UInt256 {
    return TidalProtocolUtils.div(x, y)
} 