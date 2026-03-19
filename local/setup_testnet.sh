# create pool
flow transactions send ./cadence/transactions/flow-alp/pool-factory/create_and_store_pool.cdc 'A.426f0458ced60037.MOET.Vault' --network testnet --signer testnet-deployer

# update oracle to BandOracle
flow transactions send ./cadence/transactions/flow-alp/pool-governance/update_oracle.cdc --network testnet --signer testnet-deployer

# add FLOW
flow transactions send ./cadence/transactions/flow-alp/pool-governance/add_supported_token_zero_rate_curve.cdc \
    'A.7e60df042a9c0868.FlowToken.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-deployer


# add WBTC as supported token
flow transactions send ./cadence/transactions/flow-alp/pool-governance/add_supported_token_zero_rate_curve.cdc \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_208d09d2a6dd176e3e95b3f0de172a7471c5b2d6.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-deployer

# add WETH as supported token
flow transactions send ./cadence/transactions/flow-alp/pool-governance/add_supported_token_zero_rate_curve.cdc \
    'A.dfc20aee650fcbdf.EVMVMBridgedToken_059a77239dafa770977dd9f1e98632c3e4559848.Vault' \
    0.8 \
    1.0 \
    1_000_000.0 \
    1_000_000.0 \
    --network testnet \
    --signer testnet-deployer



flow transactions send ./cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc \
  --authorizer testnet-deployer,testnet-deployer \
  --proposer testnet-deployer \
  --payer testnet-deployer \
  --network testnet

echo "swap Flow to MOET"
flow transactions send ./cadence/transactions/flow-alp/position/create_position.cdc \
	100000.0 \
	/storage/flowTokenVault \
	true \
	--network testnet --signer testnet-deployer
