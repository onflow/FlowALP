import TidalProtocol from "TidalProtocol"
import FlowToken from "FlowToken"

transaction(defaultTokenThreshold: UFix64) {
    prepare(signer: auth(SaveValue) &Account) {
        // Create a new pool with FlowToken as the default token
        let pool <- TidalProtocol.createPool(
            defaultToken: Type<@FlowToken.Vault>(),
            defaultTokenThreshold: defaultTokenThreshold
        )
        
        // Save the pool to the signer's storage
        signer.storage.save(<-pool, to: /storage/tidalPool)
    }
} 