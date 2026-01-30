## Updated Rebalance Architecture

The core philosophy is **decoupling**: each component operates independently with the least privilege necessary.

The **Supervisor** is currently in the design phase (not yet implemented).

### Key Principles

* **Isolation:** FCM, Rebalancer, and Supervisor are fully independent.
* **Least Privilege:** The Rebalancer can *only* trigger the `rebalance` function.
* **Resilience:** The `fixReschedule()` call is idempotent and permissionless, ensuring the system can recover without complex auth.

### creating a position
```mermaid
sequenceDiagram
    actor anyone
    participant FCMHelper as FCM<br/>Helper
    participant FCM
    participant AB as Rebalancer
    participant Supervisor
    anyone->>FCMHelper: createPositon()
    FCMHelper->>FCM: createPosition()
    FCMHelper->>AB: createRebalancer(rebalanceCapability)
    FCMHelper->>Supervisor: supervise(publicCapability)
```

### while running

```mermaid
sequenceDiagram
    participant AB1 as AutoRebalancer1
    participant FCM
    participant AB2 as AutoRebalancer2
    participant SUP as Supervisor
    loop every x min
    AB1->>FCM: rebalance()
    end
    loop every y min
    AB2->>FCM: rebalance()
    end
    loop every z min
    SUP->>AB2: fixReschedule()
    SUP->>AB1: fixReschedule()
    end
```