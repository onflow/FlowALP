import "TidalProtocolUtils"

access(all)
fun main(x: UInt256, y: UInt256): UInt256 {
    return TidalProtocolUtils.divUp(x, y)
} 