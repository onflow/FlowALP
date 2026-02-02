import "FlowALPv1"
import "DeFiActions"

transaction(
    pid: UInt64,
    debtType: Type,
    seizeType: Type,
    maxSeizeAmount: UFix64,
    minRepayAmount: UFix64
) {
    prepare(signer: auth(Storage) &Account) {
        let poolCap = signer.capabilities.get<&FlowALPv1.Pool>(FlowALPv1.PoolPublicPath)
        let pool = poolCap.borrow() ?? panic("Could not borrow pool")
        // Swapper must be provided by the signer via a stored resource capability; here we just assume it was passed in from the outer context
        let swapperRef = signer.capabilities.get<&{DeFiActions.Swapper}>(/public/Swapper)
        let swapper = swapperRef.borrow() ?? panic("Missing swapper capability at /public/Swapper")
        pool.liquidateViaDex(
            pid: pid,
            debtType: debtType,
            seizeType: seizeType,
            maxSeizeAmount: maxSeizeAmount,
            minRepayAmount: minRepayAmount,
            swapper: swapper,
            quote: nil
        )
    }
}
