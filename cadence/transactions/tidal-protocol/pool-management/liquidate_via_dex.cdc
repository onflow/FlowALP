import TidalProtocol from 0x0000000000000007

import FungibleToken from 0xee82856bf20e2aa6
import DeFiActions from 0x0000000000000006

transaction(
    pid: UInt64,
    debtType: Type,
    seizeType: Type,
    maxSeizeAmount: UFix64,
    minRepayAmount: UFix64,
    swapperAddr: Address,
    routePath: [Type], // Example route param
    deadline: UFix64
) {

    prepare(signer: auth(Storage) &Account) {
        // Assume pool is stored or capability exists; borrow pool
        let poolCap = signer.capabilities.get<&TidalProtocol.Pool>(/public/TidalPool)
        let pool = poolCap.borrow() ?? panic("Could not borrow pool")

        let routeParams: {String: AnyStruct} = {
            "path": routePath,
            "deadline": deadline
        }

        pool.liquidateViaDex(
            pid: pid,
            debtType: debtType,
            seizeType: seizeType,
            maxSeizeAmount: maxSeizeAmount,
            minRepayAmount: minRepayAmount,
            swapperAddr: swapperAddr,
            routeParams: routeParams
        )
    }

    execute {}
}
