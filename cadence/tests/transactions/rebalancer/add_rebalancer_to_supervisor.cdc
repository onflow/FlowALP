import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FungibleToken"
import "FlowToken"
import "FlowCron"
import "FlowCreditMarketSupervisorV1"

transaction(
    uuid: UInt64
) {
    let signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue) &Account
    let supervisor: Capability<&FlowCreditMarketSupervisorV1.Supervisor>

    prepare(signer: auth(BorrowValue, IssueStorageCapabilityController, SaveValue) &Account) {
        self.supervisor = signer.capabilities.storage.issue<&FlowCreditMarketSupervisorV1.Supervisor>(/storage/flowCreditMarketSupervisor)
        self.signer = signer
    }

    execute {
        self.supervisor.borrow()!.addPaidRebalancer(uuid: uuid)
    }
}