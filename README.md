# FlowALP — Flow Active Lending Protocol (Enshrined DeFi)

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](https://unlicense.org/)
[![Release](https://img.shields.io/github/v/release/onflow/FlowALP?include_prereleases&sort=semver)](https://github.com/onflow/FlowALP/releases)
[![Discord](https://img.shields.io/discord/613813861610684416?label=Flow%20Discord&logo=discord)](https://discord.gg/flow)
[![Built on Flow](https://img.shields.io/badge/Built%20on-Flow-00EF8B)](https://flow.com)
[![Cadence](https://img.shields.io/badge/Cadence-Smart%20Contracts-333)](https://cadence-lang.org)

## 📊 Project Status

- **Contract**: ✅ Implemented in Cadence (token-agnostic via `FungibleToken.Vault`)
- **Tests**: ✅ Cadence test suite under `cadence/tests/` (`*_test.cdc`)
- **Coverage**: 🔎 Run `flow test --cover` locally (coverage artifacts are not committed)
- **Documentation**: ✅ Complete
- **Standards**: ✅ Uses `FungibleToken` + integrates with `DeFiActions`
- **FlowVault Removal**: ✅ FlowVault is not required by the `FlowALPv0` implementation (legacy `cadence/contracts/AlpenFlow_dete_original.cdc` remains for reference)

## 🎯 Integration Milestones

### Current Status (Tracer Bullet Phase)

- ✅ **Smart Contract Integration**: FlowALP provides sink/source interfaces for token swapping
- ✅ **Development & Testing**: Automated testing framework for FlowALP and DefiActions
- ✅ **Repository Structure**: FlowALP code in this repo; DeFiActions comes from the `FlowActions/` submodule
- 💛 **Test Coverage**: Working towards comprehensive test suite
- 👌 **AMM Integration**: Currently using dummy swapper, real AMM deployment planned

### Upcoming (Limited Beta)

- ✅ **Documentation**: First pass documentation of FlowALP (this README)
- ✅ **Testing**: Extensive test suite for FlowALP and DefiActions
- 💛 **Sample Code**: DefiActions sample code and tutorials needed
- 👌 **Advanced Features**: Per-user limits and controlled testing capabilities

### Future (Open Beta)

- ✅ **Open Access**: Full public access to FlowALP and DefiActions
- 💛 **Documentation**: Improved documentation and tutorials
- ✅ **Sample Code**: Complete tutorials for DefiActions integration

## 🏦 About FlowALP

FlowALP is a decentralized lending and borrowing protocol built on the Flow network. This repository contains the current Cadence implementation deployed as the `FlowALPv0` contract. It is token-agnostic (operates over any `FungibleToken.Vault`) and integrates with DeFi Actions for composability.

### Key Features

- **Token Agnostic**: Supports any `FungibleToken.Vault` implementation (no `FlowVault` dependency)
- **DeFi Actions Integration**: Composable with other DeFi protocols via Sink/Source interfaces
- **Vault Operations**: Secure deposit and withdraw functionality
- **Position Management**: Create and manage lending/borrowing positions
- **Interest Mechanics**: Compound interest calculations with configurable rates
- **Health Monitoring**: Real-time position health calculations and overdraft protection
- **Access Control**: Secure entitlement-based access with proper authorization

### Technical Highlights

- Provides `DeFiActions.Sink` and `DeFiActions.Source` for DeFi composability
- Uses scaled balance tracking with `UFix128` interest indices for efficient interest accrual
- Supports multiple positions per pool with independent tracking
- Includes a deposit-capacity mechanism for rate limiting and fair throughput

## 🧪 Test Suite

The project includes comprehensive tests covering all functionality. **IMPORTANT**: On a fresh clone, you must install dependencies before running tests.

```bash
# First-time setup: Install dependencies
flow deps install

# Run all tests using the test runner script (RECOMMENDED)
./run_tests.sh

# Alternative: Run all tests directly
flow test --cover

# Run specific test file
flow test cadence/tests/position_lifecycle_happy_test.cdc
```

### Test Results Summary

The suite includes test files under `cadence/tests/`:

- ✅ Core vault operations and token state management
- ✅ Position lifecycle (creation, deposits, withdrawals, rebalancing)
- ✅ Interest accrual and rate calculations (debit/credit, insurance)
- ✅ Position health constraints and liquidation
- ✅ Governance parameters and access control
- ✅ Stability and insurance collection mechanisms
- ✅ Auto-rebalancing (overcollateralized and undercollateralized)
- ✅ Security tests (type spoofing, recursive withdrawal)
- ✅ Integration tests and platform compatibility
- ✅ Mathematical precision (FlowALPMath, interest curves)

For detailed test running instructions, see [TEST_RUNNING_INSTRUCTIONS.md](./TEST_RUNNING_INSTRUCTIONS.md)

## 🚀 Quick Start

### Prerequisites

- [Flow CLI](https://developers.flow.com/tools/flow-cli/install) installed
- [Visual Studio Code](https://code.visualstudio.com/) with [Cadence extension](https://marketplace.visualstudio.com/items?itemName=onflow.cadence)

### Installation

1. Clone the repository:

```bash
git clone https://github.com/onflow/FlowALP.git
cd FlowALP
git submodule update --init --recursive
```

2. **Install dependencies (REQUIRED):**

```bash
flow deps install
```

3. Run tests:

```bash
# Recommended: Use the test runner script
./run_tests.sh

# Alternative: Run directly
flow test --cover
```

### Deploy to Emulator

1. Start the Flow emulator:

```bash
flow emulator --start
```

2. Deploy the contracts:

```bash
flow project deploy --network=emulator
```

## 📦 Project Structure

```
FlowALP/
├── cadence/
│   ├── contracts/
│   │   ├── FlowALPv0.cdc                 # Main lending protocol contract
│   │   ├── FlowALPRebalancerv1.cdc       # Rebalancer (scheduled/manual)
│   │   ├── FlowALPRebalancerPaidv1.cdc   # Managed rebalancer service
│   │   ├── FlowALPSupervisorv1.cdc       # Supervisor/registry utilities
│   │   └── mocks/                        # Mock contracts used by tests
│   ├── lib/
│   │   └── FlowALPMath.cdc               # Shared math helpers (UFix128)
│   ├── tests/
│   │   ├── test_helpers.cdc            # Shared test utilities
│   │   ├── position_lifecycle_happy_test.cdc
│   │   ├── interest_accrual_integration_test.cdc
│   │   └── ...                         # Other test files
│   ├── transactions/                   # Transaction templates
│   └── scripts/                        # Query scripts
├── FlowActions/
│   └── cadence/contracts/interfaces/
│       └── DeFiActions.cdc             # DeFi Actions interface
├── imports/                            # Generated Flow standard contracts (`flow deps install`)
├── flow.json                           # Flow configuration
├── run_tests.sh                         # Test runner
└── README.md                           # This file
```

## 🔧 Contract Architecture

### Core Components

1. **Pool**: Main lending pool managing positions and reserves
2. **Position**: User positions tracking deposits and borrows
3. **TokenState**: Per-token state including interest indices
4. **FlowALP Sink/Source**: DeFi Actions integration for composability

### Key Interfaces

- `FungibleToken.Vault`: Standard token operations
- `DeFiActions.Sink/Source`: DeFi protocol composability
- Entitlements: `FlowALPModels.EParticipant`, `FlowALPModels.EPosition`, `FlowALPModels.EGovernance`, `FlowALPModels.ERebalance`

## 🛠️ Development

### Creating a Position

The `FlowALPv0` contract uses entitlements and capability-based access. This repo provides transaction templates for common operations:

- Create and store the Pool (admin): `cadence/transactions/flow-alp/pool-factory/create_and_store_pool.cdc`
- Grant and claim the beta Pool capability (admin/user): `cadence/transactions/flow-alp/beta/publish_beta_cap.cdc` and `cadence/transactions/flow-alp/beta/claim_and_save_beta_cap.cdc`
- Create a Position (user): `cadence/transactions/flow-alp/position/create_position.cdc` (uses `pushToDrawDownSink` to control auto-borrowing)

### Running Tests

**On a fresh clone, always install dependencies first:**

```bash
# Step 1: Install dependencies (REQUIRED)
flow deps install

# Step 2: Run tests using the test runner script (RECOMMENDED)
./run_tests.sh

# Alternative: Run all tests directly
flow test --cover

# Run specific test file
flow test cadence/tests/interest_accrual_integration_test.cdc

# Run specific test by name
flow test cadence/tests/interest_curve_advanced_test.cdc --name test_exact_compounding_verification_one_year
```

## 📚 Documentation

### Current Documentation

- [Test Running Instructions](./TEST_RUNNING_INSTRUCTIONS.md) - How to run tests reliably
- [Test Coverage Analysis](./cadence/tests/TEST_COVERAGE.md) - Test inventory and coverage notes
- [TODO and Missing Tests Summary](./TODO_AND_MISSING_TESTS_SUMMARY.md) - Outstanding test gaps and follow-ups
- [Cadence Testing Best Practices](./CadenceTestingBestPractices.md) - Testing guidelines

### Planning & Roadmap

- [Future Features](./FutureFeatures.md) - Upcoming development

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is released into the public domain under [The Unlicense](./LICENSE).

## 🔗 Resources

- [Flow Documentation](https://developers.flow.com/)
- [Cadence Language](https://cadence-lang.org/)
- [FungibleToken Standard](https://github.com/onflow/flow-ft)
- [DeFi Actions](https://github.com/onflow/defiactions)
- [Flow Discord](https://discord.gg/flow)
## About Flow

This repo is part of the [Flow network](https://flow.com), a Layer 1 blockchain built for consumer applications, AI Agents, and DeFi at scale.

- Developer docs: https://developers.flow.com
- Cadence language: https://cadence-lang.org
- Community: [Flow Discord](https://discord.gg/flow) · [Flow Forum](https://forum.flow.com)
- Governance: [Flow Improvement Proposals](https://github.com/onflow/flips)
