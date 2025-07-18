# Tidal Milestones

## Legend
- ✅ **Must Have** - Critical features required for launch
- 💛 **Should Have** - Important features that significantly enhance the product
- 👌 **Could Have** - Desirable features that would improve the user experience
- ❌ **Won't Have (this time)** - Features planned for future releases

## Tracer Bullet

### Frontend & User Experience
- ✅ Frontend connects to Flow wallet, allows a user to create and view the details of at least one Tide. It will support a single collateral type (a crypto, not a stable), and a single investment type (i.e. yield token).
- 👌 Multiple Tides per account.
- ✅ Frontend provides accurate details about the Tide, compiled using event data. (i.e. a backend). For this milestone, the details can be minimal (i.e. number of trades), just to show that we are tracking on-chain events.
- ✅ Frontend constructs a transaction that "glues together" TidalProtocol with DefiActions to create the Tide. Signed and submitted by Flow Wallet.
- ✅ Frontend adds the initial collateral tokens to the position during setup and triggers a rebalance to kick off the initial purchase of yield tokens.
- 👌 Frontend allows deposit/withdrawal to adjust the size of a Tide.

### Smart Contract Integration
- ✅ The Tide set up by frontend takes tokens pushed out of TidalProtocol (via a sink) and swaps them into a dummy yield bearing token. Uses a dummy Swapper interface that just magically swaps tokens without an AMM.
- ✅ The Tide set up by the frontend provides tokens requested by TidalProtocol (via a source) that are swapped out of the yield bearing token. Same dummy Swapper interface as above.
- ✅ Collateral is a crypto (possibly FLOW), native USDA used as source and sink, investment is a crypto.
- 👌 Use a real AMM deployed in the test environment.

### Price Oracle & Rebalancing
- ✅ A dummy price oracle will provide the price of the collateral and investment tokens. We must be able to easily manipulate the price provided for testing.
- ✅ We will manually increase the price of the collateral, and manually trigger a rebalance in TidalProtocol. Additional yield tokens should be purchased.
- ✅ We will manually decrease the price of the collateral, and manually trigger a rebalance. Yield tokens should be sold to repay the debt.
- 💛 We will manually increase the price of the yield token, and trigger the autobalancer. Yield tokens should be swapped into collateral tokens and deposited into the position. When we manually trigger a rebalance, the investment position should increase to reflect the extra collateral.

### User Operations
- ✅ The user can delete the tide and get back their crypto.
- ❌ Wrap the Tide into a neat package inside the user's account.

### Development & Testing
- ✅ The tracer bullet can run on emulator or testnet, with a soft preference for emulator (to keep eyes off of our secret sauce until we're ready to announce).
- ✅ Automated testing framework for TidalProtocol and DefiActions.
- 💛 Test suite that covers the functionality required for Tidal.
- ✅ Tidal and TidalProtocol code in a private repo.
- ✅ DefiActions code in a public repo.

## Limited Beta

### Frontend & User Experience
- ✅ Frontend connects to Flow wallet, allows the user to create and view any number of Tides.
- ✅ Frontend provides accurate details about each Tide, including:
  - Number of trades
  - List of trades (exportable as CSV for taxes)
  - IRR for the lifetime of the position, in absolute terms and annualized
- ✅ Frontend allows deposit, withdrawal, and deletion of any Tide.

### Asset Support
- ✅ Supports 2 collateral types: FLOW, USD. Supports at 2 yield tokens (local to Flow).
- 💛 Support BTC, ETH as collateral.
- 👌 Support up to three bridged yield tokens.

### Smart Contract Architecture
- ✅ A Tide resource will be created in the user's account to encapsulate whatever objects are needed to manage the Tide.

### Oracles & Automation
- ✅ All oracles are accurate and transparent.
- 💛 All oracles should be operated by non-FF entities.
- ✅ All Tides will rebalance periodically as the price of the collateral tokens change.
- ✅ All Tides will accumulate additional collateral as the price of the investment changes.
- 💛 Rebalancing/accumulation uses the protocol scheduled callback mechanism (if available).
- 👌 Rebalances/accumulation are triggered manually by a daemon process.

### Access Control
- ✅ Access to TidalProtocol is limited to Tidal users and the TidalProtocol team.
- ✅ Tidal is invite only, but includes a "sign up" with some kind of queuing system so we can allow additional users into the system over time.
- ✅ Tidal enforces a configurable limit on the total collateral value for each user. (Deposits are blocked if the collateral value is above the limit, but natural price growth doesn't cause problems.) The limit can be changed over time.
- 👌 Per user limits to allow controlled testing of larger positions.

### Documentation & Testing
- ✅ First pass documentation of TidalProtocol.
- ✅ DefiActions available to all devs.
- ✅ First pass documentation of DefiActions.
- 💛 Sample code for DefiActions.
- ✅ Extensive test suite for TidalProtocol, DefiActions, and any Tidal-specific smart contracts.
- 💛 Test suites should be available, with instructions, for anyone to run locally with minimal effort.
- ✅ All code (including Tidal) in public repos.

### Marketing Idea
💡 **IDEA**: When you connect during closed beta, if you don't have access, we let you join the queue. We optionally ask for an email address to notify you, but we also post your Cadence account address to the Tidal Twitter feed when you are given access. Imagine a twitter feed of hundreds or thousands of addresses saying "0x39a830 has been unlocked for access to Tidal!" Could be fun!

## Open Beta

### Core Requirements
All MUSTs from above, except those related to gated access.

### Access & Availability
- ✅ Open access to Tidal, TidalProtocol, and DefiActions.

### Asset Support
- ✅ Support BTC, ETH as collateral.
- ✅ Support up to three bridged yield tokens.

### Infrastructure
- 💛 All oracles should be operated by non-FF entities. (VERY strong should.)
- 💛 Rebalancing/accumulation uses the protocol scheduled callback mechanism (if available).
- 👌 Rebalances/accumulation are triggered manually by a daemon process.

### Documentation
- 💛 Improved documentation for Tidal, TidalProtocol, and DefiActions.
- ✅ Sample code and tutorials for DefiActions.

