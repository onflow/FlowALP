/// Returns the current block timestamp for debugging purposes
access(all) fun main(): UFix64 {
    return getCurrentBlock().timestamp
}
