#test_fork(network: "mainnet", height: nil)

import Test

access(all) struct ContractSpec {
    access(all) let path: String
    access(all) let arguments: [AnyStruct]

    init(
        path: String,
        arguments: [AnyStruct]
    ) {
        self.path = path
        self.arguments = arguments
    }
}

/// Extract contract name from path
/// "../../contracts/FlowALPv0.cdc" -> "FlowALPv0"
access(all) fun contractNameFromPath(path: String): String {
    // Split by "/"
    let parts = path.split(separator: "/")
    let file = parts[parts.length - 1]

    // Remove ".cdc"
    let nameParts = file.split(separator: ".")
    return nameParts[0]
}

access(all) fun deployAndExpectSuccess(_ contractSpec: ContractSpec) {
    let name = contractNameFromPath(path: contractSpec.path)

    log("Deploying ".concat(name).concat("..."))

    let err = Test.deployContract(
        name: name,
        path: contractSpec.path,
        arguments: contractSpec.arguments
    )

    Test.expect(err, Test.beNil())
    Test.commitBlock()
}

access(all) fun setup() {
    log("==== FlowActions Backward-Compatibility Redeploy Test ====")

    let contractsSpecs: [ContractSpec] = [
        ContractSpec(
            path: "../../lib/FlowALPMath.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/MOET.cdc",
            arguments: [0.0]
        ),
        ContractSpec(
            path: "../../contracts/FlowALPv0.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowALPRebalancerv1.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowALPRebalancerPaidv1.cdc",
            arguments: []
        ),
        ContractSpec(
            path: "../../contracts/FlowALPSupervisorv1.cdc",
            arguments: []
        )
    ]

    for contractSpec in contractsSpecs {
        deployAndExpectSuccess(contractSpec)
    }

    log("==== All FlowALP contracts redeployed successfully ====")
}

access(all) fun testAllContractsRedeployedWithoutError() {
    log("All FlowALP contracts redeployed without error (verified in setup)")
}
