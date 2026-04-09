/// ReserveVaultManager — Proposed Module
///
/// PURPOSE: Isolate custody of FungibleToken reserve vaults behind a narrow, purpose-specific API.
///
/// PROBLEM SOLVED: In the current architecture, `PoolState.borrowReserve(type)` returns an
/// `auth(FungibleToken.Withdraw) &{FungibleToken.Vault}` — a fully authorized vault reference.
/// Any code path with `EImplementation` can withdraw arbitrary amounts for any reason.
/// This makes it difficult for auditors to verify that reserves are only drained through
/// sanctioned paths (user withdrawals, liquidation seizures, fee collection).
///
/// SOLUTION: Replace the flat reserve storage with a resource that exposes purpose-specific
/// withdrawal functions, each with its own entitlement. Deposits remain open (anyone can add
/// funds), but withdrawals require the caller to declare *why* they are withdrawing, and each
/// path can enforce its own invariants.
///
/// INVARIANTS:
/// - Reserve vaults are never directly exposed; all access is through typed methods.
/// - Each withdrawal path is gated by a distinct entitlement (EReserveWithdrawForPosition,
///   EReserveWithdrawForLiquidation, EReserveWithdrawForFee).
/// - The deposit path does not require special entitlements (matches current behavior).
///
/// NOTE: This is an interface proposal. It does NOT compile or replace existing contracts.
///       It is intended to communicate the design, not to be deployed as-is.

import "FungibleToken"

access(all) contract ReserveVaultManager {

    // --- Entitlements ---

    /// Required to withdraw reserves on behalf of a user position (normal withdrawals).
    access(all) entitlement EReserveWithdrawForPosition

    /// Required to withdraw reserves during a liquidation seizure.
    access(all) entitlement EReserveWithdrawForLiquidation

    /// Required to withdraw reserves for fee collection (insurance, stability).
    access(all) entitlement EReserveWithdrawForFee

    // --- Resource Interface ---

    /// ReserveManager defines the custodial interface for all pool reserves.
    ///
    /// Design principles:
    /// 1. Deposits are unrestricted (anyone can add funds to reserves).
    /// 2. Withdrawals are purpose-specific, each gated by a distinct entitlement.
    /// 3. The resource itself holds the vaults — no one else has a direct reference.
    ///
    access(all) resource interface ReserveManager {

        // --- Read-only ---

        /// Returns the current reserve balance for the given token type, or 0 if no reserve exists.
        access(all) view fun balance(type: Type): UFix64

        /// Returns whether a reserve vault exists for the given token type.
        access(all) view fun hasReserve(type: Type): Bool

        // --- Deposits (unrestricted) ---

        /// Deposits funds into the reserve for the given token type.
        /// Creates a new reserve vault if one does not exist.
        /// This is called during user deposits and liquidation repayments.
        access(all) fun deposit(from: @{FungibleToken.Vault})

        // --- Position Withdrawals ---

        /// Withdraws funds from reserves to service a user withdrawal.
        ///
        /// The caller must provide the position ID and token type. The ReserveManager
        /// does NOT enforce health checks — that is the coordinator's responsibility.
        /// But it does record the withdrawal for auditability.
        ///
        /// @param type: The token type to withdraw
        /// @param amount: The amount to withdraw
        /// @param pid: The position ID requesting the withdrawal (for audit trail)
        /// @return The withdrawn vault
        access(EReserveWithdrawForPosition) fun withdrawForPosition(
            type: Type,
            amount: UFix64,
            pid: UInt64
        ): @{FungibleToken.Vault}

        // --- Liquidation Withdrawals ---

        /// Withdraws collateral from reserves during a liquidation seizure.
        ///
        /// @param seizeType: The collateral token type being seized
        /// @param seizeAmount: The amount of collateral to seize
        /// @param pid: The position being liquidated (for audit trail)
        /// @return The seized collateral vault
        access(EReserveWithdrawForLiquidation) fun withdrawForLiquidation(
            seizeType: Type,
            seizeAmount: UFix64,
            pid: UInt64
        ): @{FungibleToken.Vault}

        // --- Fee Collection Withdrawals ---

        /// Withdraws funds from reserves for insurance fee collection.
        ///
        /// @param type: The token type to withdraw for insurance
        /// @param amount: The calculated insurance fee amount
        /// @return The withdrawn vault (to be swapped to MOET)
        access(EReserveWithdrawForFee) fun withdrawForInsurance(
            type: Type,
            amount: UFix64
        ): @{FungibleToken.Vault}

        /// Withdraws funds from reserves for stability fee collection.
        ///
        /// @param type: The token type to withdraw for stability
        /// @param amount: The calculated stability fee amount
        /// @return The withdrawn vault (to be deposited to stability fund)
        access(EReserveWithdrawForFee) fun withdrawForStability(
            type: Type,
            amount: UFix64
        ): @{FungibleToken.Vault}
    }

    // --- Example Concrete Implementation (sketch) ---

    /// ReserveManagerImpl stores the actual vaults and implements the interface.
    ///
    /// In production, this would replace the `reserves` field in PoolStateImpl.
    ///
    access(all) resource ReserveManagerImpl: ReserveManager {

        /// Reserve vaults, keyed by token type.
        access(self) var vaults: @{Type: {FungibleToken.Vault}}

        init() {
            self.vaults <- {}
        }

        access(all) view fun balance(type: Type): UFix64 {
            if let ref = &self.vaults[type] as &{FungibleToken.Vault}? {
                return ref.balance
            }
            return 0.0
        }

        access(all) view fun hasReserve(type: Type): Bool {
            return self.vaults[type] != nil
        }

        access(all) fun deposit(from: @{FungibleToken.Vault}) {
            let type = from.getType()
            if self.vaults[type] == nil {
                self.vaults[type] <-! from
            } else {
                let ref = (&self.vaults[type] as &{FungibleToken.Vault}?)!
                ref.deposit(from: <-from)
            }
        }

        access(EReserveWithdrawForPosition) fun withdrawForPosition(
            type: Type,
            amount: UFix64,
            pid: UInt64
        ): @{FungibleToken.Vault} {
            let ref = (&self.vaults[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)
                ?? panic("No reserve for type \(type.identifier)")
            return <- ref.withdraw(amount: amount)
        }

        access(EReserveWithdrawForLiquidation) fun withdrawForLiquidation(
            seizeType: Type,
            seizeAmount: UFix64,
            pid: UInt64
        ): @{FungibleToken.Vault} {
            let ref = (&self.vaults[seizeType] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)
                ?? panic("No reserve for type \(seizeType.identifier)")
            return <- ref.withdraw(amount: seizeAmount)
        }

        access(EReserveWithdrawForFee) fun withdrawForInsurance(
            type: Type,
            amount: UFix64
        ): @{FungibleToken.Vault} {
            let ref = (&self.vaults[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)
                ?? panic("No reserve for type \(type.identifier)")
            return <- ref.withdraw(amount: amount)
        }

        access(EReserveWithdrawForFee) fun withdrawForStability(
            type: Type,
            amount: UFix64
        ): @{FungibleToken.Vault} {
            let ref = (&self.vaults[type] as auth(FungibleToken.Withdraw) &{FungibleToken.Vault}?)
                ?? panic("No reserve for type \(type.identifier)")
            return <- ref.withdraw(amount: amount)
        }
    }

    /// Creates a new ReserveManagerImpl resource.
    access(all) fun createReserveManager(): @ReserveManagerImpl {
        return <- create ReserveManagerImpl()
    }
}
