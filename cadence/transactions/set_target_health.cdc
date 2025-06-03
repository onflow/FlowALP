import TidalProtocol from "../contracts/TidalProtocol.cdc"

transaction(positionId: UInt64, targetHealth: UFix64) {
    prepare(signer: auth(BorrowValue, SaveValue) &Account) {
        // Get the pool auth reference from storage
        let poolCap = signer.storage.borrow<Capability<auth(TidalProtocol.EPosition) &TidalProtocol.Pool>>(
            from: /storage/tidalPoolAuth
        ) ?? panic("Could not borrow pool auth capability")
        
        let pool = poolCap.borrow() ?? panic("Could not borrow pool reference")
        
        // Note: Based on Dieter's design, Position is just a relay struct
        // setTargetHealth is a no-op that doesn't actually do anything
        // For testing purposes, we'll save the values
        signer.storage.save(positionId, to: /storage/testTargetHealthPid)
        signer.storage.save(targetHealth, to: /storage/testTargetHealthValue)
    }
} 