access(all) contract TidalProtocolClosedBeta {

    // 1) Define an entitlement only the admin can issue
    access(all) entitlement Admin

    access(all) resource interface IBeta {}
    access(all) resource BetaBadge: IBeta {}

    access(all) let BetaBadgeStoragePath: StoragePath
    access(all) let AdminHandleStoragePath: StoragePath

    // 2) A small in-account helper resource that performs privileged ops
    access(all) resource AdminHandle {
        access(Admin) fun grantBeta(to: auth(Storage) &Account) {
            pre {
                to.storage.type(at: TidalProtocolClosedBeta.BetaBadgeStoragePath) == nil:
                    "BetaBadge already exists for this account"
            }
            to.storage.save(<-create BetaBadge(), to: TidalProtocolClosedBeta.BetaBadgeStoragePath)
        }
        access(Admin) fun revokeBeta(from: auth(Storage) &Account) {
            pre {
                from.storage.type(at: TidalProtocolClosedBeta.BetaBadgeStoragePath) != nil:
                    "No BetaBadge to revoke"
            }
            let badge <- from.storage.load<@BetaBadge>(from: TidalProtocolClosedBeta.BetaBadgeStoragePath)
                ?? panic("Missing BetaBadge")
            destroy badge
        }
    }

    // ===== Account-gated core =====

    access(all) fun betaRef(): &{IBeta} {
        return self.account.storage
            .borrow<&{IBeta}>(from: self.BetaBadgeStoragePath)
            ?? panic("Beta badge missing on strategies account")
    }

    init() {
        self.BetaBadgeStoragePath = StoragePath(
            identifier: "TidalProtocolBetaBadge_\(self.account.address)"
        )!
        self.AdminHandleStoragePath = StoragePath(
            identifier: "TidalProtocolClosedBetaAdmin_\(self.account.address)"
        )!

        // Create and store the admin handle in *this* (deployer) account
        self.account.storage.save(<-create AdminHandle(), to: self.AdminHandleStoragePath)
    }
}
