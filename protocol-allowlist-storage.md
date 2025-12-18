# Protocol Allowlist Storage - Where to Save User Preferences

**Your Question:** Where do we save each user's approved list of protocols/vaults?

**Short Answer:** **On-chain in the smart contract** (for security enforcement) + **off-chain cache** (for fast UI reads).

---

## Why Storage Location Matters

### ❌ Wrong Approach: Off-Chain Only (Database)

```
User approves: [Kinetic, Firelight]
→ Saved in PostgreSQL database
→ AI reads from database
→ AI rebalances based on database

PROBLEM: AI could ignore database and use any protocol!
→ No cryptographic enforcement
→ Requires trusting Kimera's backend
→ NOT truly non-custodial
```

**Verdict:** ❌ Insecure, defeats the purpose of non-custodial design

---

### ✅ Correct Approach: On-Chain (Smart Contract)

```
User approves: [Kinetic, Firelight]
→ Transaction sent to blockchain
→ Stored in smart contract state
→ AI attempts rebalance
→ Smart contract ENFORCES allowlist
→ If protocol not approved → transaction REVERTS

BENEFIT: Cryptographically enforced, trustless
→ AI cannot bypass even if compromised
→ Truly non-custodial
```

**Verdict:** ✅ Secure, trustless, correct architecture

---

### 🎯 Best Approach: Hybrid (On-Chain + Off-Chain Cache)

```
User approves: [Kinetic, Firelight]
→ Transaction sent to blockchain (source of truth)
→ Event emitted: ProtocolApproved(user, Kinetic)
→ Backend listens to event
→ Cache in database for fast UI reads

AI reads from cache (fast)
→ Builds transaction
→ Smart contract validates against on-chain data (enforced)
→ If mismatch → transaction reverts

UI reads from cache (instant)
→ Shows user their current preferences
→ Periodically sync with blockchain
```

**Verdict:** ✅ Best of both worlds (performance + security)

---

## Implementation: Simple Vault Architecture

### Smart Contract Storage

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract KimeraVault is ReentrancyGuard {
    IERC20 public immutable FXRP;

    // ============ USER DATA STORAGE ============

    // User => total balance
    mapping(address => uint256) public balances;

    // User => authorized AI agent address
    mapping(address => address) public authorizedAgents;

    // User => protocol address => is approved
    mapping(address => mapping(address => bool)) public approvedProtocols;

    // User => array of approved protocol addresses (for enumeration)
    mapping(address => address[]) private userProtocolList;

    // User => protocol => index in array (for efficient removal)
    mapping(address => mapping(address => uint256)) private protocolIndex;

    // ============ EVENTS ============

    event ProtocolApproved(address indexed user, address indexed protocol);
    event ProtocolRevoked(address indexed user, address indexed protocol);
    event AgentAuthorized(address indexed user, address indexed agent);
    event AgentRevoked(address indexed user);
    event Rebalanced(
        address indexed user,
        address indexed fromProtocol,
        address indexed toProtocol,
        uint256 amount
    );

    // ============ USER FUNCTIONS ============

    /**
     * @notice Approve a protocol for AI agent to use
     * @param protocol Address of the protocol contract
     */
    function approveProtocol(address protocol) external {
        require(protocol != address(0), "Invalid protocol");
        require(!approvedProtocols[msg.sender][protocol], "Already approved");

        approvedProtocols[msg.sender][protocol] = true;

        // Add to enumeration array
        protocolIndex[msg.sender][protocol] = userProtocolList[msg.sender].length;
        userProtocolList[msg.sender].push(protocol);

        emit ProtocolApproved(msg.sender, protocol);
    }

    /**
     * @notice Approve multiple protocols at once (gas optimization)
     * @param protocols Array of protocol addresses
     */
    function approveProtocolsBatch(address[] calldata protocols) external {
        for (uint i = 0; i < protocols.length; i++) {
            address protocol = protocols[i];

            require(protocol != address(0), "Invalid protocol");

            if (!approvedProtocols[msg.sender][protocol]) {
                approvedProtocols[msg.sender][protocol] = true;
                protocolIndex[msg.sender][protocol] = userProtocolList[msg.sender].length;
                userProtocolList[msg.sender].push(protocol);

                emit ProtocolApproved(msg.sender, protocol);
            }
        }
    }

    /**
     * @notice Revoke approval for a protocol
     * @param protocol Address of the protocol contract
     */
    function revokeProtocol(address protocol) external {
        require(approvedProtocols[msg.sender][protocol], "Not approved");

        approvedProtocols[msg.sender][protocol] = false;

        // Remove from array (swap with last element)
        uint256 index = protocolIndex[msg.sender][protocol];
        uint256 lastIndex = userProtocolList[msg.sender].length - 1;

        if (index != lastIndex) {
            address lastProtocol = userProtocolList[msg.sender][lastIndex];
            userProtocolList[msg.sender][index] = lastProtocol;
            protocolIndex[msg.sender][lastProtocol] = index;
        }

        userProtocolList[msg.sender].pop();
        delete protocolIndex[msg.sender][protocol];

        emit ProtocolRevoked(msg.sender, protocol);
    }

    /**
     * @notice Get all approved protocols for a user
     * @param user User address
     * @return Array of approved protocol addresses
     */
    function getApprovedProtocols(address user) external view returns (address[] memory) {
        return userProtocolList[user];
    }

    /**
     * @notice Check if a protocol is approved for a user
     * @param user User address
     * @param protocol Protocol address
     * @return True if approved
     */
    function isProtocolApproved(address user, address protocol) external view returns (bool) {
        return approvedProtocols[user][protocol];
    }

    // ============ AI AGENT FUNCTIONS ============

    /**
     * @notice Rebalance user funds between protocols
     * @param user User whose funds to rebalance
     * @param fromProtocol Protocol to withdraw from (or address(0) for vault)
     * @param toProtocol Protocol to deposit to (or address(0) for vault)
     * @param amount Amount of FXRP to move
     * @param withdrawData Calldata for withdrawal
     * @param depositData Calldata for deposit
     */
    function rebalance(
        address user,
        address fromProtocol,
        address toProtocol,
        uint256 amount,
        bytes calldata withdrawData,
        bytes calldata depositData
    ) external nonReentrant {
        // 1. Validate caller is authorized agent
        require(msg.sender == authorizedAgents[user], "Not authorized agent");

        // 2. Validate protocols are approved
        if (fromProtocol != address(0)) {
            require(approvedProtocols[user][fromProtocol], "From protocol not approved");
        }
        if (toProtocol != address(0)) {
            require(approvedProtocols[user][toProtocol], "To protocol not approved");
        }

        // 3. Validate user has sufficient balance
        require(balances[user] >= amount, "Insufficient balance");

        // 4. Execute withdrawal
        if (fromProtocol != address(0)) {
            (bool success, ) = fromProtocol.call(withdrawData);
            require(success, "Withdraw failed");
        }

        // 5. Execute deposit
        if (toProtocol != address(0)) {
            FXRP.approve(toProtocol, amount);
            (bool success, ) = toProtocol.call(depositData);
            require(success, "Deposit failed");
        }

        emit Rebalanced(user, fromProtocol, toProtocol, amount);
    }

    // ... other functions (deposit, withdraw, etc.)
}
```

### Data Structure Breakdown

#### Storage Layout
```
User: 0xAlice
├── balances[0xAlice] = 1000 FXRP
├── authorizedAgents[0xAlice] = 0xAI_Agent
├── approvedProtocols[0xAlice][0xKinetic] = true
├── approvedProtocols[0xAlice][0xFirelight] = true
├── approvedProtocols[0xAlice][0xVaultX] = false
└── userProtocolList[0xAlice] = [0xKinetic, 0xFirelight]

User: 0xBob
├── balances[0xBob] = 5000 FXRP
├── authorizedAgents[0xBob] = 0xAI_Agent
├── approvedProtocols[0xBob][0xKinetic] = true
└── userProtocolList[0xBob] = [0xKinetic]
```

#### Why Two Mappings?

**1. `approvedProtocols` mapping:**
```solidity
mapping(address => mapping(address => bool))
```
- **Purpose:** O(1) lookup for validation
- **Used by:** AI agent during rebalance (gas-efficient)
- **Example:** `approvedProtocols[alice][kinetic] == true` → instant check

**2. `userProtocolList` array:**
```solidity
mapping(address => address[])
```
- **Purpose:** Enumerate all approved protocols
- **Used by:** Frontend to display user preferences
- **Example:** `getApprovedProtocols(alice)` → `[Kinetic, Firelight]`

---

## Implementation: ERC-4337 Architecture

### Smart Account with Session Key Module

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@account-abstraction/contracts/core/BaseAccount.sol";

contract KimeraSmartAccount is BaseAccount {
    address public owner;
    ISessionKeyModule public sessionKeyModule;

    // ============ USER PREFERENCE STORAGE ============

    // Protocol address => is approved
    mapping(address => bool) public approvedProtocols;

    // Array of approved protocols (for enumeration)
    address[] private protocolList;

    // Protocol => index in array
    mapping(address => uint256) private protocolIndex;

    // ============ EVENTS ============

    event ProtocolApproved(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);

    // ============ MODIFIERS ============

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyEntryPointOrOwner() {
        require(
            msg.sender == address(entryPoint()) || msg.sender == owner,
            "Only EntryPoint or owner"
        );
        _;
    }

    // ============ USER FUNCTIONS ============

    function approveProtocol(address protocol) external onlyOwner {
        require(protocol != address(0), "Invalid protocol");
        require(!approvedProtocols[protocol], "Already approved");

        approvedProtocols[protocol] = true;
        protocolIndex[protocol] = protocolList.length;
        protocolList.push(protocol);

        emit ProtocolApproved(protocol);
    }

    function approveProtocolsBatch(address[] calldata protocols) external onlyOwner {
        for (uint i = 0; i < protocols.length; i++) {
            if (!approvedProtocols[protocols[i]]) {
                approvedProtocols[protocols[i]] = true;
                protocolIndex[protocols[i]] = protocolList.length;
                protocolList.push(protocols[i]);
                emit ProtocolApproved(protocols[i]);
            }
        }
    }

    function revokeProtocol(address protocol) external onlyOwner {
        require(approvedProtocols[protocol], "Not approved");

        approvedProtocols[protocol] = false;

        uint256 index = protocolIndex[protocol];
        uint256 lastIndex = protocolList.length - 1;

        if (index != lastIndex) {
            address lastProtocol = protocolList[lastIndex];
            protocolList[index] = lastProtocol;
            protocolIndex[lastProtocol] = index;
        }

        protocolList.pop();
        delete protocolIndex[protocol];

        emit ProtocolRevoked(protocol);
    }

    function getApprovedProtocols() external view returns (address[] memory) {
        return protocolList;
    }

    // ============ EXECUTION WITH VALIDATION ============

    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyEntryPointOrOwner {
        // Validate target is approved protocol
        require(approvedProtocols[target], "Protocol not approved");

        (bool success, bytes memory result) = target.call{value: value}(data);
        require(success, string(result));
    }

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata dataArray
    ) external onlyEntryPointOrOwner {
        require(targets.length == values.length && values.length == dataArray.length, "Length mismatch");

        for (uint i = 0; i < targets.length; i++) {
            // Validate each target is approved
            require(approvedProtocols[targets[i]], "Protocol not approved");

            (bool success, bytes memory result) = targets[i].call{value: values[i]}(dataArray[i]);
            require(success, string(result));
        }
    }

    // ... ERC-4337 implementation details
}
```

---

## Off-Chain Cache (Backend Database)

### Database Schema

```sql
-- PostgreSQL schema

CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    address VARCHAR(42) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE approved_protocols (
    id SERIAL PRIMARY KEY,
    user_address VARCHAR(42) NOT NULL,
    protocol_address VARCHAR(42) NOT NULL,
    protocol_name VARCHAR(100),
    approved_at TIMESTAMP DEFAULT NOW(),
    UNIQUE(user_address, protocol_address),
    FOREIGN KEY (user_address) REFERENCES users(address)
);

CREATE INDEX idx_user_protocols ON approved_protocols(user_address);

-- Cache table for fast reads
CREATE TABLE protocol_preferences_cache (
    user_address VARCHAR(42) PRIMARY KEY,
    approved_protocols JSONB, -- Array of protocol addresses
    last_synced_block BIGINT,
    last_updated TIMESTAMP DEFAULT NOW()
);
```

### Event Listener (Sync On-Chain → Off-Chain)

```javascript
// backend/services/blockchain-sync.js

const { ethers } = require('ethers');

class BlockchainSyncService {
    constructor(provider, vaultContract, database) {
        this.provider = provider;
        this.vault = vaultContract;
        this.db = database;
    }

    async startListening() {
        // Listen for ProtocolApproved events
        this.vault.on('ProtocolApproved', async (user, protocol, event) => {
            console.log(`User ${user} approved protocol ${protocol}`);

            await this.db.query(
                `INSERT INTO approved_protocols (user_address, protocol_address, protocol_name)
                 VALUES ($1, $2, $3)
                 ON CONFLICT (user_address, protocol_address) DO NOTHING`,
                [user.toLowerCase(), protocol.toLowerCase(), await this.getProtocolName(protocol)]
            );

            // Update cache
            await this.updateCache(user);
        });

        // Listen for ProtocolRevoked events
        this.vault.on('ProtocolRevoked', async (user, protocol, event) => {
            console.log(`User ${user} revoked protocol ${protocol}`);

            await this.db.query(
                `DELETE FROM approved_protocols
                 WHERE user_address = $1 AND protocol_address = $2`,
                [user.toLowerCase(), protocol.toLowerCase()]
            );

            // Update cache
            await this.updateCache(user);
        });

        console.log('Blockchain event listener started');
    }

    async updateCache(userAddress) {
        // Read from contract (source of truth)
        const protocols = await this.vault.getApprovedProtocols(userAddress);
        const blockNumber = await this.provider.getBlockNumber();

        await this.db.query(
            `INSERT INTO protocol_preferences_cache (user_address, approved_protocols, last_synced_block)
             VALUES ($1, $2, $3)
             ON CONFLICT (user_address)
             DO UPDATE SET
                 approved_protocols = $2,
                 last_synced_block = $3,
                 last_updated = NOW()`,
            [userAddress.toLowerCase(), JSON.stringify(protocols), blockNumber]
        );
    }

    async getProtocolName(address) {
        // Lookup protocol name from registry or contract
        const registry = {
            '0x123...': 'Kinetic',
            '0x456...': 'Firelight',
            // ...
        };
        return registry[address.toLowerCase()] || 'Unknown';
    }

    // Periodic full sync (backup, in case events were missed)
    async fullSync() {
        const users = await this.db.query('SELECT address FROM users');

        for (const user of users.rows) {
            await this.updateCache(user.address);
        }

        console.log(`Full sync completed for ${users.rows.length} users`);
    }
}

module.exports = BlockchainSyncService;
```

---

## How the AI Agent Reads User Preferences

### Approach 1: Read from Cache (Fast)

```javascript
// backend/services/ai-agent.js

class AIAgent {
    async optimizeYield(userAddress) {
        // 1. Read from cache (fast, ~1ms)
        const cacheResult = await db.query(
            `SELECT approved_protocols FROM protocol_preferences_cache
             WHERE user_address = $1`,
            [userAddress.toLowerCase()]
        );

        const approvedProtocols = cacheResult.rows[0]?.approved_protocols || [];

        // 2. Fetch APYs for approved protocols only
        const yields = await this.fetchYields(approvedProtocols);

        // 3. Find best opportunity
        const currentProtocol = await this.getCurrentPosition(userAddress);
        const bestProtocol = this.findBestYield(yields);

        // 4. Build rebalance transaction
        if (this.shouldRebalance(currentProtocol, bestProtocol)) {
            // Contract will validate on-chain, so cache mismatch = revert
            return this.buildRebalanceTx(userAddress, currentProtocol, bestProtocol);
        }

        return null; // No action needed
    }
}
```

### Approach 2: Read from Blockchain (Authoritative)

```javascript
class AIAgent {
    async optimizeYield(userAddress) {
        // 1. Read directly from contract (slower, ~100ms, but authoritative)
        const approvedProtocols = await vaultContract.getApprovedProtocols(userAddress);

        // 2. Rest of logic same as above
        // ...
    }
}
```

### Hybrid: Read from Cache, Validate On-Chain

```javascript
class AIAgent {
    async optimizeYield(userAddress) {
        // 1. Read from cache for speed
        const cachedProtocols = await this.getCachedProtocols(userAddress);

        // 2. Build transaction based on cache
        const tx = await this.buildRebalanceTx(userAddress, cachedProtocols);

        // 3. Submit to blockchain
        // If cache is wrong, contract will revert → we catch and re-sync
        try {
            const receipt = await tx.send();
            return receipt;
        } catch (error) {
            if (error.message.includes('Protocol not approved')) {
                // Cache was stale, re-sync
                await this.syncUserPreferences(userAddress);
                throw new Error('Protocol preferences changed, please retry');
            }
            throw error;
        }
    }
}
```

**Best Practice:** Use cache for reads, rely on contract for enforcement.

---

## User Flow: Managing Protocol Preferences

### Frontend UI

```typescript
// frontend/components/ProtocolSelector.tsx

import { useState, useEffect } from 'react';
import { useAccount, useContract } from 'wagmi';

export default function ProtocolSelector() {
    const { address } = useAccount();
    const vault = useContract({ address: VAULT_ADDRESS, abi: VAULT_ABI });

    const [approvedProtocols, setApprovedProtocols] = useState<string[]>([]);
    const [availableProtocols, setAvailableProtocols] = useState([
        { address: '0x123...', name: 'Kinetic', apy: 5.2, risk: 'Low' },
        { address: '0x456...', name: 'Firelight', apy: 6.8, risk: 'Medium' },
        { address: '0x789...', name: 'Vault X', apy: 4.1, risk: 'Low' },
    ]);

    useEffect(() => {
        loadUserPreferences();
    }, [address]);

    async function loadUserPreferences() {
        // Read from cache API (fast)
        const response = await fetch(`/api/users/${address}/protocols`);
        const data = await response.json();
        setApprovedProtocols(data.approvedProtocols);
    }

    async function toggleProtocol(protocolAddress: string, isApproved: boolean) {
        if (isApproved) {
            // Approve protocol
            const tx = await vault.approveProtocol(protocolAddress);
            await tx.wait();
            setApprovedProtocols([...approvedProtocols, protocolAddress]);
        } else {
            // Revoke protocol
            const tx = await vault.revokeProtocol(protocolAddress);
            await tx.wait();
            setApprovedProtocols(approvedProtocols.filter(p => p !== protocolAddress));
        }
    }

    return (
        <div className="protocol-selector">
            <h2>Select Protocols for AI Agent</h2>
            <p>The AI can only use protocols you approve</p>

            {availableProtocols.map(protocol => (
                <div key={protocol.address} className="protocol-card">
                    <input
                        type="checkbox"
                        checked={approvedProtocols.includes(protocol.address)}
                        onChange={(e) => toggleProtocol(protocol.address, e.target.checked)}
                    />
                    <div>
                        <h3>{protocol.name}</h3>
                        <p>APY: {protocol.apy}%</p>
                        <p>Risk: {protocol.risk}</p>
                    </div>
                </div>
            ))}
        </div>
    );
}
```

### User Experience

**Step 1: Initial Setup**
```
┌─────────────────────────────────────┐
│ Select Protocols                    │
├─────────────────────────────────────┤
│ ☑ Kinetic (5.2% APY) - Low Risk    │
│ ☑ Firelight (6.8% APY) - Med Risk  │
│ ☐ Vault X (4.1% APY) - Low Risk    │
│                                     │
│ [Save Preferences]                  │
└─────────────────────────────────────┘

User clicks Save
→ Transaction: approveProtocolsBatch([Kinetic, Firelight])
→ Gas: ~0.8 FLR
→ Saved on-chain ✓
```

**Step 2: Update Preferences Later**
```
User decides Firelight is too risky
→ Unchecks Firelight
→ Transaction: revokeProtocol(Firelight)
→ Gas: ~0.5 FLR
→ Updated on-chain ✓
→ AI can no longer use Firelight
```

---

## Gas Cost Analysis

### Simple Vault

| Operation | Gas Cost | USD Cost (@0.02 FLR/gas) |
|-----------|----------|--------------------------|
| **approveProtocol()** (1 protocol) | ~50k gas | ~$0.02 |
| **approveProtocolsBatch()** (3 protocols) | ~120k gas | ~$0.05 |
| **revokeProtocol()** | ~30k gas | ~$0.01 |
| **getApprovedProtocols()** (view) | 0 gas | $0 |

### ERC-4337

| Operation | Gas Cost | USD Cost |
|-----------|----------|----------|
| **approveProtocol()** via UserOp | ~80k gas | $0 (paymaster) |
| **approveProtocolsBatch()** via UserOp | ~150k gas | $0 (paymaster) |
| **Cost to Kimera** | Same as above | $0.03-0.06 per update |

---

## Optimization: Gas-Efficient Batch Updates

### Allow Preset Configurations

```solidity
contract KimeraVault {
    // Predefined protocol sets
    enum RiskProfile { Conservative, Moderate, Aggressive }

    mapping(RiskProfile => address[]) public presetProtocols;

    constructor() {
        // Conservative: Only lowest risk protocols
        presetProtocols[RiskProfile.Conservative] = [KINETIC_ADDRESS, VAULT_X_ADDRESS];

        // Moderate: Mix of low and medium risk
        presetProtocols[RiskProfile.Moderate] = [KINETIC_ADDRESS, FIRELIGHT_ADDRESS, VAULT_X_ADDRESS];

        // Aggressive: All available protocols
        presetProtocols[RiskProfile.Aggressive] = [KINETIC_ADDRESS, FIRELIGHT_ADDRESS, VAULT_X_ADDRESS, HIGH_RISK_ADDRESS];
    }

    /**
     * @notice Set protocols based on risk profile (gas-efficient)
     */
    function setRiskProfile(RiskProfile profile) external {
        // Clear existing approvals
        address[] memory current = userProtocolList[msg.sender];
        for (uint i = 0; i < current.length; i++) {
            approvedProtocols[msg.sender][current[i]] = false;
        }
        delete userProtocolList[msg.sender];

        // Apply preset
        address[] memory protocols = presetProtocols[profile];
        for (uint i = 0; i < protocols.length; i++) {
            approvedProtocols[msg.sender][protocols[i]] = true;
            userProtocolList[msg.sender].push(protocols[i]);
        }

        emit RiskProfileUpdated(msg.sender, profile);
    }
}
```

**User Experience:**
```
Instead of:
[✓] Kinetic [✓] Firelight [✓] Vault X → 3 transactions

User selects:
Risk Profile: ● Conservative ○ Moderate ○ Aggressive
→ 1 transaction, same result
```

---

## Summary: Where to Store Protocol Preferences

### ✅ Recommended Architecture

```
Storage Layer:
├── On-Chain (Smart Contract) ← Source of truth, enforced
│   ├── mapping(user => mapping(protocol => bool))
│   └── mapping(user => address[])
│
└── Off-Chain (Database) ← Cache, for fast reads
    ├── PostgreSQL: approved_protocols table
    └── Redis: protocol_preferences_cache (optional)

Data Flow:
1. User updates preference → Transaction to blockchain
2. Event emitted → Backend listens
3. Database updated → Cache refreshed
4. AI reads from cache → Builds transaction
5. Contract validates → Enforces allowlist
```

### Key Principles

1. **On-chain = Enforcement**
   - Smart contract MUST validate
   - Cannot be bypassed by AI

2. **Off-chain = Performance**
   - Cache for fast UI reads
   - AI can read quickly
   - But contract is final authority

3. **Events = Synchronization**
   - Listen to blockchain events
   - Keep cache in sync
   - Periodic full sync as backup

4. **Gas Optimization**
   - Batch operations when possible
   - Preset configurations
   - Cache view functions

### Cost Comparison

| Approach | Storage | Gas Cost | Security | Performance |
|----------|---------|----------|----------|-------------|
| **On-chain only** | Contract | High | ✅ Perfect | 🟡 Slow reads |
| **Off-chain only** | Database | None | ❌ Insecure | ✅ Fast |
| **Hybrid (recommended)** | Both | Medium | ✅ Perfect | ✅ Fast |

**Winner:** Hybrid approach (best of both worlds)

---

## Implementation Checklist

- [ ] Smart contract storage (mappings + arrays)
- [ ] Approval/revoke functions
- [ ] Batch operations for gas efficiency
- [ ] Events for all state changes
- [ ] Database schema for cache
- [ ] Event listener service
- [ ] API endpoints for UI
- [ ] Periodic sync job (backup)
- [ ] Frontend UI for preferences
- [ ] AI agent integration

**Questions? Let me know if you want to see any specific implementation details!**
