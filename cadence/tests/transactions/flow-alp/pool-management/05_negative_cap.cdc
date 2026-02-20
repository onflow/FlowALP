import "FlowALPv0"

// Intentionally executed by a NON-ADMIN account.
// Expected: PANIC when trying to borrow a governance-authorized ref.
transaction() {

    prepare(nonAdmin: auth(Capabilities) &Account) {
        // Non-admin tries to issue a capability to the *admin’s* PoolFactory path.
        // This account does NOT have the PoolFactory stored at that path, so the borrow() must fail.
        let badGovCap: Capability<auth(FlowALPv0.EGovernance) &FlowALPv0.PoolFactory> =
            nonAdmin.capabilities.storage.issue<auth(FlowALPv0.EGovernance) &FlowALPv0.PoolFactory>(
                FlowALPv0.PoolFactoryPath
            )

        // This will return nil, triggering the panic — which is what we WANT in this negative test.
        let _ = badGovCap.borrow()
            ?? panic("Negative test passed: non-admin cannot borrow governance ref to PoolFactory")
    }
}
