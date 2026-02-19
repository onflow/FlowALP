#!/bin/bash
#
# Manual Liquidation Smoke Test on Mainnet Fork
#
# Prerequisites:
#   - A mainnet fork is running locally (ports 3569/8888/8080)
#   - flow.json is configured with mainnet-fork network and accounts
#
# This test:
#   1. Switches the pool to use MockOracle and MockDexSwapper
#   2. Creates user and liquidator accounts
#   3. User opens a position (deposit FLOW, borrow MOET)
#   4. Attempts manual liquidation (should FAIL - position is healthy)
#   5. Drops FLOW price to make position unhealthy
#   6. Attempts manual liquidation (should SUCCEED)

set -euo pipefail

NETWORK="mainnet-fork"
DEPLOYER="mainnet-fork-deployer"         # 6b00ff876c299c61 - FlowALP protocol account
FYV_DEPLOYER="mainnet-fork-fyv-deployer" # b1d63873c3cc9f79 - MockOracle/MockDex deployer
FLOW_SOURCE="fork-flow-source"           # 92674150c9213fc9 - well-funded FLOW account

FLOW_TOKEN_ID="A.1654653399040a61.FlowToken.Vault"
MOET_TOKEN_ID="A.6b00ff876c299c61.MOET.Vault"
MOET_VAULT_STORAGE_PATH="/storage/moetTokenVault_0x6b00ff876c299c61"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Temporary files for key management
TMPDIR_TEST="${TMPDIR:-/tmp}/fork-test-$$"
mkdir -p "$TMPDIR_TEST"
KEY_FILE="$TMPDIR_TEST/test-key.pkey"

# Track whether we modified flow.json
FLOW_JSON_BACKUP="$TMPDIR_TEST/flow.json.backup"
MODIFIED_FLOW_JSON=false

cleanup() {
    if [ "$MODIFIED_FLOW_JSON" = true ] && [ -f "$FLOW_JSON_BACKUP" ]; then
        echo "Restoring flow.json..."
        cp "$FLOW_JSON_BACKUP" flow.json
    fi
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# Helper: send a transaction and assert success
send_tx() {
    local description="$1"
    shift
    echo ">> $description"
    if ! flow transactions send "$@" --network "$NETWORK"; then
        echo "FAIL: $description"
        exit 1
    fi
    echo ""
}

# Helper: send a transaction and assert failure (reverted on-chain)
send_tx_expect_fail() {
    local description="$1"
    shift
    echo ">> $description (expecting failure)"
    # Capture output; the CLI may return non-zero for reverted txns
    local result
    result=$(flow transactions send "$@" --network "$NETWORK" --output json 2>&1) || true
    # Check if the transaction had an error (statusCode != 0 means reverted)
    local status_code
    status_code=$(echo "$result" | jq -r '.statusCode // 0' 2>/dev/null || echo "1")
    if [ "$status_code" = "0" ]; then
        # Also check for explicit error field
        local has_error
        has_error=$(echo "$result" | jq -r 'if .error then "yes" else "no" end' 2>/dev/null || echo "no")
        if [ "$has_error" = "no" ]; then
            echo "FAIL: Expected transaction to fail but it succeeded: $description"
            echo "$result" | jq . 2>/dev/null || echo "$result"
            exit 1
        fi
    fi
    echo "  (transaction failed as expected)"
    echo ""
}

# Helper: execute a script
run_script() {
    local description="$1"
    shift
    echo ">> $description"
    flow scripts execute "$@" --network "$NETWORK"
    echo ""
}

echo "============================================"
echo "  Manual Liquidation Smoke Test (Fork)"
echo "============================================"
echo ""

# --------------------------------------------------------------------------
# Step 0: Generate a test key pair and back up flow.json
# --------------------------------------------------------------------------
echo "--- Step 0: Setup ---"
cp flow.json "$FLOW_JSON_BACKUP"
MODIFIED_FLOW_JSON=true

KEY_JSON=$(flow keys generate --output json --sig-algo ECDSA_P256)
PRIV_KEY=$(echo "$KEY_JSON" | jq -r '.private')
PUB_KEY=$(echo "$KEY_JSON" | jq -r '.public')
printf '%s' "$PRIV_KEY" > "$KEY_FILE"
echo "Generated test key pair"

# Add the FLOW source account (well-funded mainnet account, using emulator key since fork doesn't check sigs)
jq '.accounts["fork-flow-source"] = {"address": "92674150c9213fc9", "key": {"type": "file", "location": "emulator-account.pkey"}}' \
    flow.json > "$TMPDIR_TEST/flow.json.tmp" && mv "$TMPDIR_TEST/flow.json.tmp" flow.json
echo "Added FLOW source account to flow.json"
echo ""

# --------------------------------------------------------------------------
# Step 1: Switch pool to MockOracle and MockDexSwapper
# --------------------------------------------------------------------------
echo "--- Step 1: Configure pool with mock oracle and DEX ---"

send_tx "Set MockOracle on pool" \
    ./fork-test/transactions/set_mock_oracle.cdc \
    --signer "$DEPLOYER"

send_tx "Set MockDexSwapper on pool" \
    ./fork-test/transactions/set_mock_dex.cdc \
    --signer "$DEPLOYER"

# Set FLOW price = 1.0 MOET in the oracle
send_tx "Set oracle price: FLOW = 1.0" \
    ./cadence/tests/transactions/mock-oracle/set_price.cdc \
    "$FLOW_TOKEN_ID" 1.0 \
    --signer "$FYV_DEPLOYER"

# Set DEX price: 1 FLOW -> 1 MOET (priceRatio = 1.0)
send_tx "Set DEX price: FLOW/MOET = 1.0" \
    ./cadence/tests/transactions/mock-dex-swapper/set_mock_dex_price_for_pair.cdc \
    "$FLOW_TOKEN_ID" "$MOET_TOKEN_ID" "$MOET_VAULT_STORAGE_PATH" 1.0 \
    --signer "$DEPLOYER"

echo ""

# --------------------------------------------------------------------------
# Step 2: Create user and liquidator accounts
# --------------------------------------------------------------------------
echo "--- Step 2: Create test accounts ---"

USER_RESULT=$(flow accounts create --key "$PUB_KEY" --signer "$DEPLOYER" --network "$NETWORK" --output json)
USER_ADDR=$(echo "$USER_RESULT" | jq -r '.address')
echo "Created user account: $USER_ADDR"

LIQUIDATOR_RESULT=$(flow accounts create --key "$PUB_KEY" --signer "$DEPLOYER" --network "$NETWORK" --output json)
LIQUIDATOR_ADDR=$(echo "$LIQUIDATOR_RESULT" | jq -r '.address')
echo "Created liquidator account: $LIQUIDATOR_ADDR"

# Add test accounts to flow.json (using the generated key)
jq --arg addr "${USER_ADDR#0x}" --arg keyfile "$KEY_FILE" \
    '.accounts["fork-user"] = {"address": $addr, "key": {"type": "file", "location": $keyfile}}' \
    flow.json > "$TMPDIR_TEST/flow.json.tmp" && mv "$TMPDIR_TEST/flow.json.tmp" flow.json

jq --arg addr "${LIQUIDATOR_ADDR#0x}" --arg keyfile "$KEY_FILE" \
    '.accounts["fork-liquidator"] = {"address": $addr, "key": {"type": "file", "location": $keyfile}}' \
    flow.json > "$TMPDIR_TEST/flow.json.tmp" && mv "$TMPDIR_TEST/flow.json.tmp" flow.json

echo ""

# --------------------------------------------------------------------------
# Step 3: Fund accounts
# --------------------------------------------------------------------------
echo "--- Step 3: Fund accounts ---"

# Transfer FLOW to user from well-funded account
send_tx "Transfer 1000 FLOW to user" \
    ./cadence/transactions/flowtoken/transfer_flowtoken.cdc \
    "$USER_ADDR" 1000.0 \
    --signer "$FLOW_SOURCE"

# Setup MOET vault for liquidator
send_tx "Setup MOET vault for liquidator" \
    ./cadence/transactions/moet/setup_vault.cdc \
    --signer fork-liquidator

# Mint MOET to liquidator (signer must have MOET Minter - the deployer account)
send_tx "Mint 1000 MOET to liquidator" \
    ./cadence/transactions/moet/mint_moet.cdc \
    "$LIQUIDATOR_ADDR" 1000.0 \
    --signer "$DEPLOYER"

# Also setup MOET vault for user (needed for receiving borrowed MOET)
send_tx "Setup MOET vault for user" \
    ./cadence/transactions/moet/setup_vault.cdc \
    --signer fork-user

# Setup FLOW receiver for liquidator (all accounts have FlowToken vault by default,
# but the liquidator account was just created so it should already have one)

echo ""

# --------------------------------------------------------------------------
# Step 4: Grant beta access and create position
# --------------------------------------------------------------------------
echo "--- Step 4: Grant beta access and open position ---"

# Grant beta pool access to user (requires both admin and user as signers)
send_tx "Grant beta pool access to user" \
    ./cadence/tests/transactions/flow-alp/pool-management/03_grant_beta.cdc \
    --authorizer "$DEPLOYER",fork-user \
    --proposer "$DEPLOYER" \
    --payer "$DEPLOYER"

# User creates position: deposit 1000 FLOW, borrow MOET
echo ">> User creates position (deposit 1000 FLOW)"
CREATE_POS_RESULT=$(flow transactions send \
    ./cadence/transactions/flow-alp/position/create_position.cdc \
    1000.0 /storage/flowTokenVault true \
    --signer fork-user --network "$NETWORK" --output json)

if echo "$CREATE_POS_RESULT" | jq -e '.error' > /dev/null 2>&1; then
    echo "FAIL: User creates position"
    echo "$CREATE_POS_RESULT" | jq -r '.error'
    exit 1
fi
echo "  Position created successfully"

# Extract position ID from the Rebalanced event (which contains the pid)
PID=$(echo "$CREATE_POS_RESULT" | jq '[.events[] | select(.type | contains("FlowALPv0.Rebalanced")) | .values.value.fields[] | select(.name == "pid") | .value.value | tonumber] | first')
echo "New position ID: $PID"
echo ""

# Check position health
echo ">> Check position health (should be healthy, >= 1.0)"
HEALTH_JSON=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc "$PID" --network "$NETWORK" --output json)
HEALTH=$(echo "$HEALTH_JSON" | jq -r '.value')
echo "Position health: $HEALTH"
echo ""

# --------------------------------------------------------------------------
# Step 5: Attempt liquidation on healthy position (should FAIL)
# --------------------------------------------------------------------------
echo "--- Step 5: Attempt liquidation on healthy position (expect failure) ---"

send_tx_expect_fail "Manual liquidation on healthy position" \
    ./cadence/transactions/flow-alp/pool-management/manual_liquidation.cdc \
    "$PID" "$MOET_TOKEN_ID" "$FLOW_TOKEN_ID" 190.0 100.0 \
    --signer fork-liquidator

echo ""

# --------------------------------------------------------------------------
# Step 6: Drop FLOW price to make position unhealthy
# --------------------------------------------------------------------------
echo "--- Step 6: Drop FLOW price to 0.5 ---"

send_tx "Set oracle price: FLOW = 0.5" \
    ./cadence/tests/transactions/mock-oracle/set_price.cdc \
    "$FLOW_TOKEN_ID" 0.5 \
    --signer "$FYV_DEPLOYER"

send_tx "Set DEX price: FLOW/MOET = 0.5" \
    ./cadence/tests/transactions/mock-dex-swapper/set_mock_dex_price_for_pair.cdc \
    "$FLOW_TOKEN_ID" "$MOET_TOKEN_ID" "$MOET_VAULT_STORAGE_PATH" 0.5 \
    --signer "$DEPLOYER"

# Check position health again
echo ">> Check position health (should be unhealthy, < 1.0)"
HEALTH_JSON=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc "$PID" --network "$NETWORK" --output json)
HEALTH=$(echo "$HEALTH_JSON" | jq -r '.value')
echo "Position health after price drop: $HEALTH"
echo ""

# --------------------------------------------------------------------------
# Step 7: Manual liquidation (should SUCCEED)
# --------------------------------------------------------------------------
echo "--- Step 7: Manual liquidation on unhealthy position (expect success) ---"

# Liquidator repays 100 MOET, seizes 190 FLOW
# DEX quote for 100 MOET at price 0.5: inAmount = 100/0.5 = 200 FLOW
# seizeAmount (190) < dexQuote (200) ✓
# Post-liquidation health will be < target (1.05) ✓
send_tx "Manual liquidation: repay 100 MOET, seize 190 FLOW" \
    ./cadence/transactions/flow-alp/pool-management/manual_liquidation.cdc \
    "$PID" "$MOET_TOKEN_ID" "$FLOW_TOKEN_ID" 190.0 100.0 \
    --signer fork-liquidator

# Check post-liquidation health
echo ">> Check position health after liquidation"
HEALTH_JSON=$(flow scripts execute ./cadence/scripts/flow-alp/position_health.cdc "$PID" --network "$NETWORK" --output json)
HEALTH=$(echo "$HEALTH_JSON" | jq -r '.value')
echo "Position health after liquidation: $HEALTH"
echo ""

echo "============================================"
echo "  ALL TESTS PASSED"
echo "============================================"
