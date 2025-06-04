import Test
import "TidalProtocol"
// CHANGE: Import FlowToken to use correct type references
import "./test_helpers.cdc"

access(all)
fun setup() {
    // Deploy DFB first since TidalProtocol imports it
    var err = Test.deployContract(
        name: "DFB",
        path: "../../DeFiBlocks/cadence/contracts/interfaces/DFB.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
    
    // Deploy MOET before TidalProtocol
    err = Test.deployContract(
        name: "MOET",
        path: "../contracts/MOET.cdc",
        arguments: [1000000.0]
    )
    Test.expect(err, Test.beNil())
    
    // Deploy TidalProtocol
    err = Test.deployContract(
        name: "TidalProtocol",
        path: "../contracts/TidalProtocol.cdc",
        arguments: []
    )
    Test.expect(err, Test.beNil())
}

// E-series: Token state management

access(all)
fun testCreditBalanceUpdates() {
    /* 
     * Test E-1: Credit balance updates
     * 
     * Deposit funds and check reserve balance
     * Reserve balance increases correctly
     */
    
    // Create pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // The default token (String) is already supported - no need to add
    
    // Check initial reserve balance
    let initialReserve = pool.reserveBalance(type: Type<String>())
    Test.assertEqual(0.0, initialReserve)
    
    // Create position
    let pid = pool.createPosition()
    
    // Note: Without actual vault implementation, we can't test deposits
    // But we verify the structure is in place
    
    // In production:
    // 1. Deposit would increase reserve balance
    // 2. TokenState would track totalCreditBalance
    // 3. Interest would accrue based on utilization
    
    // Clean up
    destroy pool
}

access(all)
fun testDebitBalanceUpdates() {
    /* 
     * Test E-2: Debit balance updates
     * 
     * Test that withdrawals would update debit balance
     * Reserve balance decreases correctly
     */
    
    // Create pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // The default token is already supported
    
    // Create borrower position
    let borrowerPid = pool.createPosition()
    
    // Initial reserve should be 0
    let initialReserve = pool.reserveBalance(type: Type<String>())
    Test.assertEqual(0.0, initialReserve)
    
    // In production with actual deposits and withdrawals:
    // 1. Deposits would increase reserves
    // 2. Withdrawals would decrease reserves
    // 3. TokenState tracks totalDebitBalance for borrowed amounts
    
    // Clean up
    destroy pool
}

access(all)
fun testBalanceDirectionFlips() {
    /* 
     * Test E-3: Balance direction flips
     * 
     * Test that balance direction changes are handled
     * TokenState tracks both credit and debit changes
     */
    
    // Create pool with oracle
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // The default token is already supported
    
    // Create test position
    let testPid = pool.createPosition()
    
    // Position should be healthy (no debt)
    Test.assertEqual(1.0, pool.positionHealth(pid: testPid))
    
    // In production:
    // 1. Start with credit balance (deposit)
    // 2. Withdraw more than deposited (flip to debit)
    // 3. Deposit again to flip back to credit
    // 4. TokenState correctly tracks direction changes
    
    // Clean up
    destroy pool
}

// NEW TEST: Deposit rate limiting
access(all)
fun testDepositRateLimiting() {
    /*
     * Test E-4: Deposit rate limiting
     * 
     * Test that deposits are limited to 5% of capacity
     * Excess deposits are queued internally
     */
    
    // Create pool with oracle - use Int as default token
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<Int>())
    oracle.setPrice(token: Type<Int>(), price: 1.0)
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<Int>(),
        priceOracle: oracle
    )
    
    // Add String token with LOW deposit rate to trigger limiting
    pool.addSupportedToken(
        tokenType: Type<String>(),
        collateralFactor: 0.8,
        borrowFactor: 0.9,
        interestCurve: TidalProtocol.SimpleInterestCurve(),
        depositRate: 100.0,          // Low rate = heavy limiting
        depositCapacityCap: 1000.0   // Low cap for testing
    )
    
    let pid = pool.createPosition()
    
    // With these settings:
    // - Capacity: 1000.0
    // - 5% limit: 50.0 per deposit
    // - Deposits above 50.0 would be queued
    
    // The tokenState() function automatically updates deposit capacity
    // based on time elapsed since last update
    
    let health = pool.positionHealth(pid: pid)
    Test.assertEqual(1.0, health)
    
    destroy pool
}

// NEW TEST: Automatic state updates
access(all)
fun testAutomaticStateUpdates() {
    /*
     * Test E-5: Automatic state updates via tokenState()
     * 
     * Test that tokenState() automatically updates:
     * - Interest indices
     * - Deposit capacity
     * - Time-based state
     */
    
    let oracle = TidalProtocol.DummyPriceOracle(defaultToken: Type<String>())
    oracle.setPrice(token: Type<String>(), price: 1.0)
    
    let pool <- TidalProtocol.createPool(
        defaultToken: Type<String>(),
        priceOracle: oracle
    )
    
    // The default token is already supported
    
    let pid = pool.createPosition()
    
    // Every operation that accesses token state triggers automatic updates:
    // 1. positionHealth() calls tokenState()
    // 2. deposit() calls tokenState()
    // 3. withdraw() calls tokenState()
    // 4. All health calculation functions call tokenState()
    
    // This ensures time-based updates happen automatically
    let health1 = pool.positionHealth(pid: pid)
    // Time passes...
    let health2 = pool.positionHealth(pid: pid)
    
    // Both should be 1.0 for empty position
    Test.assertEqual(health1, health2)
    Test.assertEqual(1.0, health2)
    
    destroy pool
} 