import "Burner"
import "MetadataViews"
import "FungibleToken"
import "FlowToken"
import "FlowTransactionScheduler"
import "FlowCreditMarket"

/// FlowCreditMarketRegistry
///
/// This contract defines constructs for managing registration of Positions on a per-Pool basis. On registration, a
/// rebalance handler is initialized and scheduled for the first rebalance. The rebalance handler is responsible for
/// scheduling subsequent rebalance transactions for the position.
///
/// The registry also manages the default rebalance configuration for all registered positions and provides the ability
/// to set a custom per-position rebalance configuration in the event such functionality is added in the future.
///
/// NOTE: Position rebalancing can fail for reasons outside of FCM's control. It's recommended that monitoring systems
/// account for instances where rebalance and subsequent RebalanceHandler transaction scheduling fail and the FCM
/// maintainers to start up the rebalancing process again. It may be desirable to add such functionality into the
/// Position objects themselves so that end users or upstream protocols/platforms can start up the rebalancing process
/// themselves.
///
access(all) contract FlowCreditMarketRegistry {

    /// Emitted when a position is registered in the registry
    access(all) event Registered(poolUUID: UInt64, positionID: UInt64, registryUUID: UInt64)
    /// Emitted when a position is unregistered from the registry
    access(all) event Unregistered(poolUUID: UInt64, positionID: UInt64, registryUUID: UInt64)
    /// Emitted when an error occurs in the rebalance handler
    access(all) event RebalanceHandlerError(poolUUID: UInt64, positionID: UInt64, registryUUID: UInt64, whileExecuting: UInt64?, errorMessage: String)
    
    /// Registry
    ///
    /// A resource that manages the registration and unregistration of positions in the registry associated with the
    /// identified pool. It also manages the scheduling of rebalance transactions for the registered positions.
    ///
    /// The registry is associated with a pool and each position in the pool has an associated rebalance handler.
    /// The rebalance handler is responsible for scheduling rebalance transactions for the position.
    ///
    /// The registry is also responsible for managing the default rebalance configuration for all registered positions
    /// and provides the ability to set a custom per-position rebalance configuration in the event such functionality is
    /// added in the future.
    access(all) resource Registry : FlowCreditMarket.IRegistry {
        /// A map of registered positions by their Position ID
        access(all) let registeredPositions: {UInt64: Bool}
        /// The default rebalance configuration for all registered positions
        /// See RebalanceHandler.scheduleNextRebalance for the expected configuration format
        access(all) var defaultRebalanceRecurringConfig: {String: AnyStruct}
        /// A map of custom rebalance configurations by position ID. While not currently supported in FCM, adding this
        /// allows for extensibility in the event governance chooses to add custom rebalance configurations for
        /// registered positions in the future.
        /// See RebalanceHandler.scheduleNextRebalance for the expected configuration format
        access(all) let rebalanceConfigs: {UInt64: {String: AnyStruct}}

        init(defaultRebalanceRecurringConfig: {String: AnyStruct}) {
            self.registeredPositions = {}
            self.defaultRebalanceRecurringConfig = defaultRebalanceRecurringConfig
            self.rebalanceConfigs = {}
        }

        /// Returns the rebalance configuration for the identified position
        ///
        /// @param pid: The ID of the position
        ///
        /// @return {String: AnyStruct}: The rebalance configuration for the position
        access(all) view fun getRebalanceHandlerScheduledTxnConfig(pid: UInt64): {String: AnyStruct} {
            return self.rebalanceConfigs[pid] ?? self.defaultRebalanceRecurringConfig
        }

        /// Registers a position in the registry associated with the identified pool and position ID
        ///
        /// @param poolUUID: The UUID of the pool
        /// @param pid: The ID of the position
        /// @param rebalanceConfig: The rebalance configuration for the position
        access(FlowCreditMarket.Register) fun registerPosition(poolUUID: UInt64, pid: UInt64, rebalanceConfig: {String: AnyStruct}?) {
            pre {
                self.registeredPositions[pid] == nil:
                "Position \(pid) is already registered"
                FlowCreditMarketRegistry._borrowAuthPool(poolUUID)?.positionExists(pid: pid) == true:
                "Position \(pid) does not exist in pool \(poolUUID) - cannot register non-existent position"
            }
            self.registeredPositions[pid] = true
            if rebalanceConfig != nil {
                self.rebalanceConfigs[pid] = rebalanceConfig!
            }

            // configure a rebalance handler for this position identified by it's pool:position
            let rebalanceHandler = FlowCreditMarketRegistry._initRebalanceHandler(poolUUID: poolUUID, positionID: pid)

            // emit the registered event
            emit Registered(poolUUID: poolUUID, positionID: pid, registryUUID: self.uuid)

            // schedule the first rebalance
            rebalanceHandler.scheduleNextRebalance(whileExecuting: nil, data: rebalanceConfig ?? self.defaultRebalanceRecurringConfig)
        }

        /// Unregisters a position in the registry associated with the identified pool and position ID
        ///
        /// @param poolUUID: The UUID of the pool
        /// @param pid: The ID of the position
        ///
        /// @return Bool: True if the position was unregistered, false otherwise
        access(FlowCreditMarket.Register) fun unregisterPosition(poolUUID: UInt64, pid: UInt64): Bool {
            let removed = self.registeredPositions.remove(key: pid)
            if removed == true {
                emit Unregistered(poolUUID: poolUUID, positionID: pid, registryUUID: self.uuid)
                FlowCreditMarketRegistry._cleanupRebalanceHandler(poolUUID: poolUUID, positionID: pid)
            }
            return removed == true
        }

        /// Sets the default rebalance recurring configuration for the registry
        ///
        /// @param config: The default rebalance configuration for all registered positions
        access(FlowCreditMarket.EGovernance) fun setDefaultRebalanceRecurringConfig(config: {String: AnyStruct}) {
            pre {
                config["interval"] as? UFix64 != nil:
                "interval: UFix64 is required"
                config["priority"] as? UInt8 != nil && (config["priority"]! as? UInt8 ?? UInt8.max) <= 2:
                "priority: UInt8 is required and must be between 0 and 2 to match FlowTransactionScheduler.Priority raw values (0: High, 1: Medium, 2: Low)"
                config["executionEffort"] as? UInt64 != nil:
                "executionEffort: UInt64 is required"
                config["force"] as? Bool != nil:
                "force: Bool is required"
            }
            self.defaultRebalanceRecurringConfig = config
        }
    }

    /// RebalanceHandler
    ///
    /// A resource that manages the scheduling of rebalance transactions for a position in a pool.
    ///
    /// The rebalance handler is associated with a pool and position and is responsible for scheduling rebalance
    /// transactions for the position.
    ///
    /// The rebalance handler is also responsible for managing the scheduled transactions for the position.
    ///
    access(all) resource RebalanceHandler : FlowTransactionScheduler.TransactionHandler {
        /// The UUID of the pool associated with the rebalance handler
        access(all) let poolUUID: UInt64
        /// The ID of the position associated with the rebalance handler
        access(all) let positionID: UInt64
        /// A map of scheduled transactions by their ID
        access(all) let scheduledTxns: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
        /// The self capability for the rebalance handler
        access(self) var selfCapability: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?

        init(poolUUID: UInt64, positionID: UInt64) {
            self.poolUUID = poolUUID
            self.positionID = positionID
            self.scheduledTxns <- {}
            self.selfCapability = nil
        }
        
        /* MetadataViews.Display conformance */
        
        /// Returns the views supported by the rebalance handler
        access(all) view fun getViews(): [Type] {
            return [ Type<StoragePath>(), Type<PublicPath>(), Type<MetadataViews.Display>() ]
        }
        /// Resolves a view type to a view object
        ///
        /// @param viewType: The type of the view to resolve
        ///
        /// @return AnyStruct?: The view object, or nil if the view is not supported
        access(all) fun resolveView(_ viewType: Type): AnyStruct? {
            if viewType == Type<StoragePath>() {
                return FlowCreditMarketRegistry.deriveRebalanceHandlerStoragePath(poolUUID: self.poolUUID, positionID: self.positionID)
            } else if viewType == Type<PublicPath>() {
                return FlowCreditMarketRegistry.deriveRebalanceHandlerPublicPath(poolUUID: self.poolUUID, positionID: self.positionID)
            } else if viewType == Type<MetadataViews.Display>() {
                return MetadataViews.Display(
                    name: "Flow Credit Market Pool Position Rebalance Scheduled Transaction Handler",
                    description: "Scheduled Transaction Handler that can execute rebalance transactions on behalf of a Flow Credit Market Pool with UUID \(self.poolUUID) and Position ID \(self.positionID)",
                    thumbnail: MetadataViews.HTTPFile(url: "")
                )
            }
            return nil
        }
        /// Returns the IDs of the scheduled transactions.
        /// NOTE: this does not include externally scheduled transactions
        ///
        /// @return [UInt64]: The IDs of the scheduled transactions
        access(all) view fun getScheduledTransactionIDs(): [UInt64] {
            return self.scheduledTxns.keys
        }
        /// Borrows a reference to the internally-managed scheduled transaction or nil if not found.
        /// NOTE: this does not include externally scheduled transactions
        ///
        /// @param id: The ID of the scheduled transaction
        ///
        /// @return &FlowTransactionScheduler.ScheduledTransaction?: The reference to the scheduled transaction, or nil 
        /// if the scheduled transaction is not found
        access(all) view fun borrowScheduledTransaction(id: UInt64): &FlowTransactionScheduler.ScheduledTransaction? {
            return &self.scheduledTxns[id]
        }
        /// Executes a scheduled rebalance on the underlying FCM Position. If the scheduled transaction is internally-managed,
        /// the next rebalance will be scheduled, otherwise the execution is treated as a "fire once" transaction.
        ///
        /// @param id: The ID of the scheduled transaction to execute
        /// @param data: The data for the scheduled transaction
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let _data = data as? {String: AnyStruct} ?? {"force": false}
            let force = _data["force"] as? Bool ?? false

            // borrow the pool
            let pool = FlowCreditMarketRegistry._borrowAuthPool(self.poolUUID)
            if pool == nil {
                emit RebalanceHandlerError(poolUUID: self.poolUUID, positionID: self.positionID, registryUUID: self.uuid, whileExecuting: id, errorMessage: "POOL_NOT_FOUND")
                return
            }

            // call rebalance on the pool
            let unwrappedPool = pool!
            // THIS CALL MAY REVERT - upstream systems should account for instances where rebalancing forces a revert
            unwrappedPool.rebalancePosition(pid: self.positionID, force: force)

            // schedule the next rebalance if internally-managed
            let isInternallyManaged = self.borrowScheduledTransaction(id: id) != nil
            if isInternallyManaged {
                let err = self.scheduleNextRebalance(whileExecuting: id, data: nil)
                if err != nil {
                    emit RebalanceHandlerError(poolUUID: self.poolUUID, positionID: self.positionID, registryUUID: self.uuid, whileExecuting: id, errorMessage: err!)
                }
            }
            // clean up internally-managed historical scheduled transactions
            self._cleanupScheduledTransactions()
        }
        /// Schedules the next rebalance on the underlying FCM Position. Defaults to the Registry's recurring config
        /// for the handled position if `data` is not provided. Otherwise the next scheduled transaction is configured
        /// with the provided data.
        ///
        /// @param whileExecuting: The ID of the scheduled transaction that is currently executing
        /// @param data: The optional recurring config for the scheduled transaction
        access(FlowCreditMarket.Schedule) fun scheduleNextRebalance(whileExecuting: UInt64?, data: {String: AnyStruct}?): String? {
            // check for a valid self capability before attempting to schedule the next rebalance
            if self.selfCapability?.check() != true { return "INVALID_SELF_CAPABILITY"; }
            let selfCapability = self.selfCapability!

            // borrow the registry & get the recurring config for this position
            let registry = FlowCreditMarketRegistry.borrowRegistry(self.poolUUID)
            if registry == nil {
                return "REGISTRY_NOT_FOUND"
            }
            let unwrappedRegistry = registry!
            let recurringConfig = data ?? unwrappedRegistry.getRebalanceHandlerScheduledTxnConfig(pid: self.positionID)
            // get the recurring config values
            let interval = recurringConfig["interval"] as? UFix64
            let priorityRaw = recurringConfig["priority"] as? UInt8
            let executionEffort = recurringConfig["executionEffort"] as? UInt64
            if interval == nil || priorityRaw == nil || (priorityRaw as? UInt8 ?? UInt8.max) > 2 || executionEffort == nil {
                return "INVALID_RECURRING_CONFIG"
            }

            // schedule the next rebalance based on the recurring config
            let priority = FlowTransactionScheduler.Priority(rawValue: priorityRaw!)!
            let timestamp = getCurrentBlock().timestamp + UFix64(interval!)
            let estimate = FlowTransactionScheduler.estimate(
                data: recurringConfig,
                timestamp: timestamp,
                priority: priority,
                executionEffort: executionEffort!
            )

            if estimate.flowFee == nil {
                return "INVALID_SCHEDULED_TXN_ESTIMATE: \(estimate.error ?? "UNKNOWN_ERROR")"
            }
            // withdraw the fees for the scheduled transaction
            let feeAmount = estimate.flowFee!
            var fees <- FlowCreditMarketRegistry._withdrawFees(amount: feeAmount)
            if fees == nil {
                destroy fees
                return "FAILED_TO_WITHDRAW_FEES"
            } else {
                // schedule the next rebalance
                let unwrappedFees <- fees!
                let txn <- FlowTransactionScheduler.schedule(
                    handlerCap: selfCapability,
                    data: recurringConfig,
                    timestamp: timestamp,
                    priority: priority,
                    executionEffort: executionEffort!,
                    fees: <-unwrappedFees
                )
                let txnID = txn.id
                self.scheduledTxns[txnID] <-! txn
                return nil
            }   
        }
        /// Sets the self capability for the rebalance handler so that it can schedule its own future transactions
        ///
        /// @param handlerCap: The capability to set for the rebalance handler
        access(contract) fun _setSelfCapability(_ handlerCap: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>) {
            pre {
                self.selfCapability == nil:
                "Self capability is already set"
                handlerCap.check() == true:
                "Handler capability is not valid"
                handlerCap.borrow()!.uuid == self.uuid:
                "Handler capability is not for this handler"
            }
            self.selfCapability = handlerCap
        }
        /// Cleans up the internally-managed scheduled transactions
        access(self) fun _cleanupScheduledTransactions() {
            // if there are no scheduled transactions, return
            if self.scheduledTxns.length == 0 {
                return
            }
            // limit to prevent running into computation limits
            let limit = 25
            // iterate over the scheduled transactions and remove those that are not scheduled
            for i, id in self.scheduledTxns.keys {
                if i >= limit {
                    break
                }
                let ref = self.borrowScheduledTransaction(id: id)
                if ref != nil && ref!.status() != FlowTransactionScheduler.Status.Scheduled {
                    destroy <- self.scheduledTxns.remove(key: id)
                }
            }
        }
    }

    /* PUBLIC METHODS */

    /// Derives the storage path for the rebalance handler associated with the identified pool and position
    ///
    /// @param poolUUID: The UUID of the pool
    /// @param positionID: The ID of the position
    ///
    /// @return StoragePath: The storage path for the rebalance handler
    access(all) view fun deriveRebalanceHandlerStoragePath(poolUUID: UInt64, positionID: UInt64): StoragePath {
        return StoragePath(identifier: "flowCreditMarketRebalanceHandler_\(poolUUID)_\(positionID)")!
    }

    /// Derives the public path for the rebalance handler associated with the identified pool and position
    ///
    /// @param poolUUID: The UUID of the pool
    /// @param positionID: The ID of the position
    ///
    /// @return PublicPath: The public path for the rebalance handler
    access(all) view fun deriveRebalanceHandlerPublicPath(poolUUID: UInt64, positionID: UInt64): PublicPath {
        return PublicPath(identifier: "flowCreditMarketRebalanceHandler_\(poolUUID)_\(positionID)")!
    }

    /// Borrows a reference to the registry associated with the identified pool
    ///
    /// @param poolUUID: The UUID of the pool
    ///
    /// @return &Registry?: The reference to the registry, or nil if the registry is not found
    access(all) view fun borrowRegistry(_ poolUUID: UInt64): &Registry? {
        let registryPath = FlowCreditMarket.deriveRegistryPublicPath(forPool: poolUUID)
        return self.account.capabilities.borrow<&Registry>(registryPath)
    }

    /// Borrows a reference to the rebalance handler associated with the identified pool and position
    ///
    /// @param poolUUID: The UUID of the pool
    /// @param positionID: The ID of the position
    ///
    /// @return &RebalanceHandler?: The reference to the rebalance handler, or nil if the rebalance handler is not found
    access(all)view fun borrowRebalanceHandler(poolUUID: UInt64, positionID: UInt64): &RebalanceHandler? {
        let handlerPath = self.deriveRebalanceHandlerPublicPath(poolUUID: poolUUID, positionID: positionID)
        return self.account.capabilities.borrow<&RebalanceHandler>(handlerPath)
    }

    /* INTERNAL METHODS */
    
    /// Initializes a new rebalance handler associated with the identified pool and position
    ///
    /// @param poolUUID: The UUID of the pool
    /// @param positionID: The ID of the position
    ///
    /// @return auth(FlowCreditMarket.Schedule) &RebalanceHandler: The initialized rebalance handler
    access(self) fun _initRebalanceHandler(poolUUID: UInt64, positionID: UInt64): auth(FlowCreditMarket.Schedule) &RebalanceHandler {
        let storagePath = self.deriveRebalanceHandlerStoragePath(poolUUID: poolUUID, positionID: positionID)
        let publicPath = self.deriveRebalanceHandlerPublicPath(poolUUID: poolUUID, positionID: positionID)
        // initialize the RebalanceHandler if it doesn't exist
        if self.account.storage.type(at: storagePath) == nil {
            let rebalanceHandler <- create RebalanceHandler(poolUUID: poolUUID, positionID: positionID)
            self.account.storage.save(<-rebalanceHandler, to: storagePath)
            self.account.capabilities.unpublish(publicPath)
            let pubCap = self.account.capabilities.storage.issue<&RebalanceHandler>(storagePath)
            self.account.capabilities.publish(pubCap, at: publicPath)
        }
        // borrow the RebalanceHandler, set its internal capability & return
        let rebalanceHandler = self.account.storage.borrow<auth(FlowCreditMarket.Schedule) &RebalanceHandler>(from: storagePath)
            ?? panic("Failed to initialize RebalanceHandler")
        let handlerCap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(storagePath)
        rebalanceHandler._setSelfCapability(handlerCap)
        return rebalanceHandler
    }

    /// Cleans up the rebalance handler associated with the identified pool and position
    ///
    /// @param poolUUID: The UUID of the pool
    /// @param positionID: The ID of the position
    access(self) fun _cleanupRebalanceHandler(poolUUID: UInt64, positionID: UInt64) {
        let storagePath = self.deriveRebalanceHandlerStoragePath(poolUUID: poolUUID, positionID: positionID)
        let publicPath = self.deriveRebalanceHandlerPublicPath(poolUUID: poolUUID, positionID: positionID)
        if self.account.storage.type(at: storagePath) == nil {
            return
        }
        self.account.capabilities.unpublish(publicPath)
        self.account.capabilities.storage.forEachController(forPath: storagePath, fun(_ controller: &StorageCapabilityController): Bool {
            controller.delete()
            return true
        })
        let removed <- self.account.storage.load<@RebalanceHandler>(from: storagePath)
        Burner.burn(<-removed)
    }

    /// Borrows a reference to the pool associated with the identified pool
    ///
    /// @param poolUUID: The UUID of the pool
    ///
    /// @return auth(FlowCreditMarket.EPosition) &FlowCreditMarket.Pool?: The reference to the pool, or nil if the pool is not found
    access(self) view fun _borrowAuthPool(_ poolUUID: UInt64): auth(FlowCreditMarket.EPosition) &FlowCreditMarket.Pool? {
        let poolPath = FlowCreditMarket.PoolStoragePath
        return self.account.storage.borrow<auth(FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>(from: poolPath)
    }

    /// Withdraws the identified amount of Flow tokens from the FlowToken vault or `nil` if the funds are unavailable
    ///
    /// @param amount: The amount of Flow tokens to withdraw
    ///
    /// @return @FlowToken.Vault?: The vault with the withdrawn amount, or nil if the withdrawal failed
    access(self) fun _withdrawFees(amount: UFix64): @FlowToken.Vault? {
        let vaultPath = /storage/flowTokenVault
        let vault = self.account.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: vaultPath)
        if vault?.balance ?? 0.0 < amount {
            return nil
        }
        return <-vault!.withdraw(amount: amount) as! @FlowToken.Vault
    }

    init() {
        let poolUUID = self.account.storage.borrow<&FlowCreditMarket.Pool>(from: FlowCreditMarket.PoolStoragePath)?.uuid
            ?? panic("Cannot initialize FlowCreditMarketScheduler without an initialized FlowCreditMarket Pool in storage")
        let storagePath = FlowCreditMarket.deriveRegistryStoragePath(forPool: poolUUID)
        let publicPath = FlowCreditMarket.deriveRegistryPublicPath(forPool: poolUUID)

        let defaultRebalanceRecurringConfig = {
                "interval": 60.0 * 10.0, // 10 minutes in seconds
                "priority": 2,           // Low priority
                "executionEffort": 999,  // 999 gas units
                "force": false           // Do not force rebalance
            }
        self.account.storage.save(<-create Registry(defaultRebalanceRecurringConfig: defaultRebalanceRecurringConfig), to: storagePath)
        let pubCap = self.account.capabilities.storage.issue<&Registry>(storagePath)
        self.account.capabilities.publish(pubCap, at: publicPath)
    }
}
