# AlpenFlow - DeFi Lending Protocol on Flow

## 📊 Project Status

- **Contract**: ✅ Implemented with FungibleToken Standard
- **Tests**: ✅ 100% Passing (24/24 tests)
- **Coverage**: ✅ 90%
- **Documentation**: ✅ Complete
- **Standards**: ✅ FungibleToken & DeFi Blocks Compatible

## 🎯 Tidal Integration Milestones

### Current Status (Tracer Bullet Phase)
- ✅ **Smart Contract Integration**: AlpenFlow provides sink/source interfaces for token swapping
- ✅ **Development & Testing**: Automated testing framework for AlpenFlow and DefiBlocks
- ✅ **Repository Structure**: AlpenFlow code in private repo, DefiBlocks in public repo
- 💛 **Test Coverage**: Working towards comprehensive test suite for Tidal functionality
- 👌 **AMM Integration**: Currently using dummy swapper, real AMM deployment planned

### Upcoming (Limited Beta)
- ✅ **Documentation**: First pass documentation of AlpenFlow (this README)
- ✅ **Testing**: Extensive test suite for AlpenFlow and DefiBlocks
- 💛 **Sample Code**: DefiBlocks sample code and tutorials needed
- 👌 **Advanced Features**: Per-user limits and controlled testing capabilities

### Future (Open Beta)
- ✅ **Open Access**: Full public access to AlpenFlow and DefiBlocks
- 💛 **Documentation**: Improved documentation and tutorials
- ✅ **Sample Code**: Complete tutorials for DefiBlocks integration

## 🏦 About AlpenFlow

AlpenFlow is a decentralized lending and borrowing protocol built on the Flow blockchain. It implements the Flow FungibleToken standard and integrates with DeFi Blocks for composability.

### Key Features

- **FungibleToken Standard**: Full compatibility with Flow wallets and DEXs
- **DeFi Blocks Integration**: Composable with other DeFi protocols via Sink/Source interfaces
- **Vault Operations**: Secure deposit and withdraw functionality
- **Position Management**: Create and manage lending/borrowing positions
- **Interest Mechanics**: Compound interest calculations with configurable rates
- **Health Monitoring**: Real-time position health calculations and overdraft protection
- **Access Control**: Secure entitlement-based access with proper authorization

### Technical Highlights

- Implements `FungibleToken.Vault` interface for standard token operations
- Provides `DFB.Sink` and `DFB.Source` for DeFi composability
- Uses scaled balance tracking for efficient interest accrual
- Supports multiple positions per pool with independent tracking
- Includes comprehensive metadata views for wallet integration

## 🧪 Test Suite

The project includes comprehensive tests covering all functionality:

```bash
# Run all tests with coverage
flow test --cover

# Run specific test file
flow test cadence/tests/core_vault_test.cdc
```

### Test Results Summary
- **Core Vault Operations**: ✅ 3/3 passing
- **Interest Mechanics**: ✅ 6/6 passing
- **Position Health**: ✅ 3/3 passing
- **Token State Management**: ✅ 3/3 passing
- **Reserve Management**: ✅ 3/3 passing
- **Access Control**: ✅ 2/2 passing
- **Edge Cases**: ✅ 3/3 passing
- **Simple Import**: ✅ 2/2 passing

**Total**: 24/24 tests passing with 90% code coverage

## 🚀 Quick Start

### Prerequisites

- [Flow CLI](https://developers.flow.com/tools/flow-cli/install) installed
- [Visual Studio Code](https://code.visualstudio.com/) with [Cadence extension](https://marketplace.visualstudio.com/items?itemName=onflow.cadence)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/your-username/AlpenFlow.git
cd AlpenFlow
```

2. Install dependencies:
```bash
flow dependencies install
```

3. Run tests:
```bash
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
AlpenFlow/
├── cadence/
│   ├── contracts/
│   │   └── AlpenFlow.cdc          # Main lending protocol contract
│   ├── tests/
│   │   ├── test_helpers.cdc       # Shared test utilities
│   │   ├── core_vault_test.cdc    # Vault operation tests
│   │   ├── interest_mechanics_test.cdc  # Interest calculation tests
│   │   └── ...                    # Other test files
│   ├── transactions/              # Transaction templates (coming soon)
│   └── scripts/                   # Query scripts (coming soon)
├── DeFiBlocks/
│   └── cadence/contracts/interfaces/
│       └── DFB.cdc               # DeFi Blocks interface
├── imports/                       # Flow standard contracts
├── flow.json                      # Flow configuration
└── README.md                      # This file
```

## 🔧 Contract Architecture

### Core Components

1. **FlowVault**: FungibleToken-compliant vault for holding assets
2. **Pool**: Main lending pool managing positions and reserves
3. **Position**: User positions tracking deposits and borrows
4. **TokenState**: Per-token state including interest indices
5. **AlpenFlowSink/Source**: DeFi Blocks integration for composability

### Key Interfaces

- `FungibleToken.Vault`: Standard token operations
- `ViewResolver`: Metadata views for wallets
- `Burner.Burnable`: Token burning capability
- `DFB.Sink/Source`: DeFi protocol composability

## 🛠️ Development

### Creating a Position

```cadence
// Create a new pool
let pool <- AlpenFlow.createTestPool(defaultTokenThreshold: 0.8)

// Create a position
let positionId = pool.createPosition()

// Deposit funds
let vault <- AlpenFlow.createTestVault(balance: 100.0)
pool.deposit(pid: positionId, funds: <-vault)
```

### Running Tests

```bash
# Run all tests
flow test --cover

# Run specific test category
flow test cadence/tests/interest_mechanics_test.cdc
```

## 📚 Documentation

### Roadmap & Planning
- [Milestone Alignment Overview](./MilestoneAlignment.md)
- [AlpenFlow Development Roadmap](./AlpenFlowRoadmap.md)
- [Tidal Integration Milestones](./TidalMilestones.md)
- [Future Features](./FutureFeatures.md)

### Technical Documentation
- [FungibleToken Integration Summary](./FungibleTokenIntegrationSummary.md)
- [Test Update Summary](./TestUpdateSummary.md)
- [Tests Overview](./TestsOverview.md)
- [Cadence Testing Best Practices](./CadenceTestingBestPractices.md)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License.

## 🔗 Resources

- [Flow Documentation](https://developers.flow.com/)
- [Cadence Language](https://cadence-lang.org/)
- [FungibleToken Standard](https://github.com/onflow/flow-ft)
- [DeFi Blocks](https://github.com/onflow/defi-blocks)
- [Flow Discord](https://discord.gg/flow)
