import "Burner"
import "MetadataViews"
import "FungibleToken"
import "FlowToken"
import "FlowTransactionScheduler"
import "FlowCreditMarket"

access(all) contract FlowCreditMarketRegistry {

    access(all) event Registered(poolUUID: UInt64, positionID: UInt64)
    access(all) event Unregistered(poolUUID: UInt64, positionID: UInt64)
    access(all) event RebalanceHandlerError(poolUUID: UInt64, positionID: UInt64, whileExecuting: UInt64?, errorMessage: String)
    
    access(all) resource Registry : FlowCreditMarket.IRegistry {
        access(all) let registeredPositions: {UInt64: Bool}
        access(all) var defaultRebalanceRecurringConfig: {String: AnyStruct}
        access(all) let rebalanceConfigs: {UInt64: {String: AnyStruct}}

        init(defaultRebalanceRecurringConfig: {String: AnyStruct}) {
            self.registeredPositions = {}
            self.defaultRebalanceRecurringConfig = defaultRebalanceRecurringConfig
            self.rebalanceConfigs = {}
        }

        access(all) view fun getRebalanceHandlerScheduledTxnData(pid: UInt64): {String: AnyStruct} {
            return self.rebalanceConfigs[pid] ?? self.defaultRebalanceRecurringConfig
        }

        access(FlowCreditMarket.Register) fun registerPosition(poolUUID: UInt64, pid: UInt64, rebalanceConfig: {String: AnyStruct}?) {
            pre {
                self.registeredPositions[pid] == nil:
                "Position \(pid) is already registered"
            }
            self.registeredPositions[pid] = true
            if rebalanceConfig != nil {
                self.rebalanceConfigs[pid] = rebalanceConfig!
            }

            // configure a rebalance handler for this position identified by it's pool:position
            let rebalanceHandler = FlowCreditMarketRegistry._initRebalanceHandler(poolUUID: poolUUID, positionID: pid)

            // emit the registered event
            emit Registered(poolUUID: poolUUID, positionID: pid)

            // schedule the first rebalance
            rebalanceHandler.scheduleNextRebalance(whileExecuting: nil, data: rebalanceConfig ?? self.defaultRebalanceRecurringConfig)
        }

        access(FlowCreditMarket.Register) fun unregisterPosition(poolUUID: UInt64, pid: UInt64): Bool {
            let removed = self.registeredPositions.remove(key: pid)
            if removed == true {
                emit Unregistered(poolUUID: poolUUID, positionID: pid)
                FlowCreditMarketRegistry._cleanupRebalanceHandler(poolUUID: poolUUID, positionID: pid)
            }
            return removed == true
        }

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

    access(all) resource RebalanceHandler : FlowTransactionScheduler.TransactionHandler {
        access(all) let poolUUID: UInt64
        access(all) let positionID: UInt64
        access(all) let scheduledTxns: @{UInt64: FlowTransactionScheduler.ScheduledTransaction}
        access(self) var selfCapability: Capability<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>?

        init(poolUUID: UInt64, positionID: UInt64) {
            self.poolUUID = poolUUID
            self.positionID = positionID
            self.scheduledTxns <- {}
            self.selfCapability = nil
        }
        
        access(all) view fun getViews(): [Type] {
            return [ Type<StoragePath>(), Type<PublicPath>() ]
        }
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
        ///
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
        ///
        access(all) view fun borrowScheduledTransaction(id: UInt64): &FlowTransactionScheduler.ScheduledTransaction? {
            return &self.scheduledTxns[id]
        }
        /// Executes a scheduled rebalance on the underlying FCM Position
        ///
        /// @param id: The ID of the scheduled transaction to execute
        /// @param data: The data for the scheduled transaction
        ///
        access(FlowTransactionScheduler.Execute) fun executeTransaction(id: UInt64, data: AnyStruct?) {
            let _data = data as? {String: AnyStruct} ?? {"force": false}
            let force = _data["force"] as? Bool ?? false

            // borrow the pool
            let pool = FlowCreditMarketRegistry._borrowAuthPool(self.poolUUID)
            if pool == nil {
                emit RebalanceHandlerError(poolUUID: self.poolUUID, positionID: self.positionID, whileExecuting: id, errorMessage: "POOL_NOT_FOUND")
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
                    emit RebalanceHandlerError(poolUUID: self.poolUUID, positionID: self.positionID, whileExecuting: id, errorMessage: err!)
                }
            }
        }
        /// Schedules the next rebalance on the underlying FCM Position
        ///
        /// @param whileExecuting: The ID of the scheduled transaction that is currently executing
        /// @param data: The data for the scheduled transaction
        ///
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
            let recurringConfig = data ?? unwrappedRegistry.getRebalanceHandlerScheduledTxnData(pid: self.positionID)
            // get the recurring config values
            let interval = recurringConfig["interval"] as? UFix64
            let priorityRaw = recurringConfig["priority"] as? UInt8
            let executionEffort = recurringConfig["executionEffort"] as? UInt64
            if interval == nil || priorityRaw == nil || executionEffort == nil || (priorityRaw! as? UInt8 ?? UInt8.max) > 2 {
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
    }

    /* PUBLIC METHODS */

    access(all) view fun deriveRebalanceHandlerStoragePath(poolUUID: UInt64, positionID: UInt64): StoragePath {
        return StoragePath(identifier: "flowCreditMarketRebalanceHandler_\(poolUUID)_\(positionID)")!
    }

    access(all) view fun deriveRebalanceHandlerPublicPath(poolUUID: UInt64, positionID: UInt64): PublicPath {
        return PublicPath(identifier: "flowCreditMarketRebalanceHandler_\(poolUUID)_\(positionID)")!
    }

    access(all) view fun borrowRegistry(_ poolUUID: UInt64): &Registry? {
        let registryPath = FlowCreditMarket.deriveRegistryPublicPath(forPool: poolUUID)
        return self.account.capabilities.borrow<&Registry>(registryPath)
    }

    access(all)view fun borrowRebalanceHandler(poolUUID: UInt64, positionID: UInt64): &RebalanceHandler? {
        let handlerPath = self.deriveRebalanceHandlerPublicPath(poolUUID: poolUUID, positionID: positionID)
        return self.account.capabilities.borrow<&RebalanceHandler>(handlerPath)
    }

    /* INTERNAL METHODS */
    
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
        let rebalanceHandler = self.account.storage.borrow<auth(FlowCreditMarket.Schedule) &RebalanceHandler>(from: storagePath) ?? panic("Failed to initialize RebalanceHandler")
        let handlerCap = self.account.capabilities.storage.issue<auth(FlowTransactionScheduler.Execute) &{FlowTransactionScheduler.TransactionHandler}>(storagePath)
        rebalanceHandler._setSelfCapability(handlerCap)
        return rebalanceHandler
    }

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

    access(self) view fun _borrowAuthPool(_ poolUUID: UInt64): auth(FlowCreditMarket.EPosition) &FlowCreditMarket.Pool? {
        let poolPath = FlowCreditMarket.PoolStoragePath
        return self.account.storage.borrow<auth(FlowCreditMarket.EPosition) &FlowCreditMarket.Pool>(from: poolPath)
    }

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
        let path = FlowCreditMarket.deriveRegistryStoragePath(forPool: poolUUID)

        // TODO: update config schema for scheduled txn data formats
        let defaultRebalanceRecurringConfig = {"force": false}
        self.account.storage.save(<-create Registry(defaultRebalanceRecurringConfig: defaultRebalanceRecurringConfig), to: path)
    }
}
