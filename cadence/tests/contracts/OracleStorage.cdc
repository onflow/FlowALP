import "DeFiActions"

access(all) contract OracleStorage {

    access(all) var oracle: {DeFiActions.PriceOracle}?

    init() {
        self.oracle = nil
    }

    access(all) fun saveOracle(oracle: {DeFiActions.PriceOracle}) {
        self.oracle = oracle
    }
}
