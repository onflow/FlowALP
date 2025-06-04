import TidalProtocol from "../contracts/TidalProtocol.cdc"

access(all) struct BalanceInfo {
    access(all) let tokenType: Type
    access(all) let balance: UFix64
    access(all) let availableBalance: UFix64

    init(tokenType: Type, balance: UFix64, availableBalance: UFix64) {
        self.tokenType = tokenType
        self.balance = balance
        self.availableBalance = availableBalance
    }
}

access(all) fun main(poolAddress: Address, positionId: UInt64): [BalanceInfo] {
    // Get the pool reference
    let pool = getAccount(poolAddress).capabilities.borrow<&TidalProtocol.Pool>(
        /public/tidalPool
    ) ?? panic("Could not borrow pool reference")

    // Get the position
    let position = pool.borrowPosition(pid: positionId)
        ?? panic("Position not found")

    // Get all balances
    let balances = position.getBalances()
    
    // Create result array
    let result: [BalanceInfo] = []
    
    for balance in balances {
        let availableBalance = position.getAvailableBalance(tokenType: balance.tokenType)
        result.append(BalanceInfo(
            tokenType: balance.tokenType,
            balance: balance.balance,
            availableBalance: availableBalance
        ))
    }
    
    return result
} 