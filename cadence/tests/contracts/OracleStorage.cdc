import "DeFiActions"

/// Test-only: holds an optional `DeFiActions.PriceOracle` (e.g. a router or
/// aggregator view) so tests can save and later use it.
access(all) contract OracleStorage {

    access(all) var oracle: {DeFiActions.PriceOracle}?

    init() {
        self.oracle = nil
    }

    /// Stores the given oracle for the test account.
    access(all) fun saveOracle(oracle: {DeFiActions.PriceOracle}) {
        self.oracle = oracle
    }
}
