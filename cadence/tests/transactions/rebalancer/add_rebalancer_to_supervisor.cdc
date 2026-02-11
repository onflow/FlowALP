import "FlowALPSupervisorv1"

transaction(
    uuid: UInt64,
    supervisorStoragePath: StoragePath
) {
    let signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue) &Account
    let supervisor: Capability<&FlowALPSupervisorv1.Supervisor>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue) &Account) {
        self.supervisor = signer.capabilities.storage.issue<&FlowALPSupervisorv1.Supervisor>(supervisorStoragePath)
        self.signer = signer
    }

    execute {
        self.supervisor.borrow()!.addPaidRebalancer(uuid: uuid)
    }
}