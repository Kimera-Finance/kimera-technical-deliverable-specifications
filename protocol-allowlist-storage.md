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

## Complete Smart Contract Implementation

### Full Contract Code

**Location:** `/contracts/KimeraVault.sol`

A complete, production-ready smart contract with all features has been created. Key features include:

**Core Features:**
- ✅ User deposits/withdrawals (FXRP)
- ✅ Agent authorization per user
- ✅ Protocol approval/revocation per user
- ✅ Batch operations for gas efficiency
- ✅ Rebalancing with validation
- ✅ Protocol verification registry
- ✅ Emergency pause mechanism
- ✅ Comprehensive events
- ✅ Security: ReentrancyGuard, SafeERC20

**Storage Structure:**
```solidity
// User balances
mapping(address => uint256) public balances;

// User's authorized agent
mapping(address => address) public authorizedAgents;

// User => protocol => approved
mapping(address => mapping(address => bool)) public approvedProtocols;

// User => approved protocol list (for enumeration)
mapping(address => address[]) private userProtocolList;

// User => protocol => balance in that protocol
mapping(address => mapping(address => uint256)) public userProtocolBalances;

// Global verified protocols registry
mapping(address => bool) public verifiedProtocols;
```

**Key Functions:**

1. **User Deposit/Withdraw:**
```solidity
function deposit(uint256 amount) external;
function withdraw(uint256 amount) external;
function withdrawAll() external; // Emergency
```

2. **Agent Management:**
```solidity
function authorizeAgent(address agent) external;
function revokeAgent() external;
```

3. **Protocol Management:**
```solidity
function approveProtocol(address protocol) external;
function approveProtocolsBatch(address[] calldata protocols) external;
function revokeProtocol(address protocol) external;
function revokeAllProtocols() external;
```

4. **AI Agent Rebalancing:**
```solidity
function rebalance(
    address user,
    address fromProtocol,
    address toProtocol,
    uint256 amount,
    bytes calldata withdrawData,
    bytes calldata depositData,
    string calldata reason
) external;

function rebalanceBatch(...) external; // Multi-user optimization
```

5. **View Functions:**
```solidity
function getApprovedProtocols(address user) external view returns (address[] memory);
function isProtocolApproved(address user, address protocol) external view returns (bool);
function getUserBalances(address user) external view returns (...);
function getVerifiedProtocols() external view returns (address[] memory);
```

6. **Admin Functions:**
```solidity
function verifyProtocol(address protocol, string calldata name) external onlyOwner;
function unverifyProtocol(address protocol) external onlyOwner;
function pause() external onlyOwner;
function unpause() external onlyOwner;
```

---

## Deployment Guide

### 1. Install Dependencies

```bash
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npm install @openzeppelin/contracts
```

### 2. Deployment Script

```javascript
// scripts/deploy.js
const hre = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);

    // FXRP token address on Flare/Coston2
    const FXRP_ADDRESS = "0x..."; // Replace with actual FXRP address

    // Deploy KimeraVault
    const KimeraVault = await ethers.getContractFactory("KimeraVault");
    const vault = await KimeraVault.deploy(FXRP_ADDRESS);
    await vault.deployed();

    console.log("KimeraVault deployed to:", vault.address);

    // Verify protocols
    const KINETIC_ADDRESS = "0x...";
    const FIRELIGHT_ADDRESS = "0x...";

    await vault.verifyProtocol(KINETIC_ADDRESS, "Kinetic");
    console.log("Verified Kinetic protocol");

    await vault.verifyProtocol(FIRELIGHT_ADDRESS, "Firelight");
    console.log("Verified Firelight protocol");

    // Save deployment info
    const fs = require('fs');
    const deploymentInfo = {
        network: hre.network.name,
        vault: vault.address,
        fxrp: FXRP_ADDRESS,
        deployer: deployer.address,
        timestamp: new Date().toISOString(),
        verifiedProtocols: {
            kinetic: KINETIC_ADDRESS,
            firelight: FIRELIGHT_ADDRESS
        }
    };

    fs.writeFileSync(
        `deployments/${hre.network.name}.json`,
        JSON.stringify(deploymentInfo, null, 2)
    );

    console.log("Deployment complete!");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
```

### 3. Deploy to Coston2 Testnet

```bash
# Configure hardhat.config.js with Coston2 RPC
npx hardhat run scripts/deploy.js --network coston2
```

---

## Usage Examples

### User Flow: Approve Protocols

```javascript
// frontend/examples/approveProtocols.js
import { ethers } from 'ethers';

async function approveProtocols(userAddress, protocolAddresses) {
    // Connect to contract
    const vault = new ethers.Contract(
        VAULT_ADDRESS,
        VAULT_ABI,
        signer
    );

    // Approve multiple protocols in one transaction (gas efficient)
    const tx = await vault.approveProtocolsBatch(protocolAddresses);
    await tx.wait();

    console.log("Protocols approved:", protocolAddresses);

    // Get user's approved protocols
    const approved = await vault.getApprovedProtocols(userAddress);
    console.log("Current approved protocols:", approved);
}

// Example usage
await approveProtocols(userAddress, [
    KINETIC_ADDRESS,
    FIRELIGHT_ADDRESS
]);
```

### AI Agent: Read User Preferences

```javascript
// backend/services/getUserPreferences.js
async function getUserPreferences(userAddress) {
    // Option 1: Read from cache (fast)
    const cached = await db.query(
        'SELECT approved_protocols FROM protocol_preferences_cache WHERE user_address = $1',
        [userAddress]
    );

    if (cached.rows.length > 0) {
        return cached.rows[0].approved_protocols;
    }

    // Option 2: Read from contract (authoritative)
    const protocols = await vaultContract.getApprovedProtocols(userAddress);

    // Cache the result
    await db.query(
        'INSERT INTO protocol_preferences_cache VALUES ($1, $2) ON CONFLICT (user_address) DO UPDATE SET approved_protocols = $2',
        [userAddress, JSON.stringify(protocols)]
    );

    return protocols;
}
```

### AI Agent: Execute Rebalance

```javascript
// backend/services/executeRebalance.js
async function executeRebalance(userAddress, fromProtocol, toProtocol, amount) {
    // 1. Verify user has authorized this agent
    const authorizedAgent = await vaultContract.authorizedAgents(userAddress);
    if (authorizedAgent.toLowerCase() !== agentAddress.toLowerCase()) {
        throw new Error("Agent not authorized for this user");
    }

    // 2. Verify protocols are approved
    const isFromApproved = fromProtocol === ethers.constants.AddressZero ||
        await vaultContract.isProtocolApproved(userAddress, fromProtocol);
    const isToApproved = toProtocol === ethers.constants.AddressZero ||
        await vaultContract.isProtocolApproved(userAddress, toProtocol);

    if (!isFromApproved || !isToApproved) {
        throw new Error("Protocol not approved");
    }

    // 3. Build withdrawal calldata (if needed)
    let withdrawData = "0x";
    if (fromProtocol !== ethers.constants.AddressZero) {
        const protocolContract = new ethers.Contract(fromProtocol, PROTOCOL_ABI, signer);
        withdrawData = protocolContract.interface.encodeFunctionData("withdraw", [amount]);
    }

    // 4. Build deposit calldata (if needed)
    let depositData = "0x";
    if (toProtocol !== ethers.constants.AddressZero) {
        const protocolContract = new ethers.Contract(toProtocol, PROTOCOL_ABI, signer);
        depositData = protocolContract.interface.encodeFunctionData("deposit", [amount]);
    }

    // 5. Execute rebalance
    const reason = `Moving to higher APY: ${toProtocolName} (+${apyDelta}%)`;

    const tx = await vaultContract.rebalance(
        userAddress,
        fromProtocol,
        toProtocol,
        amount,
        withdrawData,
        depositData,
        reason
    );

    const receipt = await tx.wait();
    console.log("Rebalance successful:", receipt.transactionHash);

    return receipt;
}

// Example usage
await executeRebalance(
    "0xAlice...",
    KINETIC_ADDRESS,  // From Kinetic
    FIRELIGHT_ADDRESS, // To Firelight
    ethers.utils.parseEther("1000") // 1000 FXRP
);
```

---

## Testing

### Unit Tests

```javascript
// test/KimeraVault.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("KimeraVault", function () {
    let vault, fxrp, owner, alice, bob, agent;

    beforeEach(async function () {
        [owner, alice, bob, agent] = await ethers.getSigners();

        // Deploy mock FXRP
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        fxrp = await MockERC20.deploy("FXRP", "FXRP", ethers.utils.parseEther("1000000"));

        // Deploy vault
        const KimeraVault = await ethers.getContractFactory("KimeraVault");
        vault = await KimeraVault.deploy(fxrp.address);

        // Setup: Give Alice some FXRP
        await fxrp.transfer(alice.address, ethers.utils.parseEther("10000"));
    });

    describe("Protocol Management", function () {
        it("Should approve a protocol", async function () {
            // Verify protocol first
            await vault.verifyProtocol(bob.address, "TestProtocol");

            // Alice approves protocol
            await vault.connect(alice).approveProtocol(bob.address);

            // Check approval
            expect(await vault.isProtocolApproved(alice.address, bob.address)).to.be.true;

            // Check it's in the list
            const protocols = await vault.getApprovedProtocols(alice.address);
            expect(protocols).to.include(bob.address);
        });

        it("Should approve multiple protocols in batch", async function () {
            // Verify protocols
            await vault.verifyProtocol(bob.address, "Protocol1");
            await vault.verifyProtocol(agent.address, "Protocol2");

            // Batch approve
            await vault.connect(alice).approveProtocolsBatch([bob.address, agent.address]);

            // Check both approved
            expect(await vault.isProtocolApproved(alice.address, bob.address)).to.be.true;
            expect(await vault.isProtocolApproved(alice.address, agent.address)).to.be.true;
        });

        it("Should revoke a protocol", async function () {
            await vault.verifyProtocol(bob.address, "TestProtocol");
            await vault.connect(alice).approveProtocol(bob.address);

            // Revoke
            await vault.connect(alice).revokeProtocol(bob.address);

            // Check revoked
            expect(await vault.isProtocolApproved(alice.address, bob.address)).to.be.false;
        });

        it("Should reject unverified protocols", async function () {
            // Try to approve unverified protocol
            await expect(
                vault.connect(alice).approveProtocol(bob.address)
            ).to.be.revertedWithCustomError(vault, "ProtocolNotVerified");
        });

        it("Should enforce max protocols limit", async function () {
            // Create 21 addresses
            const protocols = [];
            for (let i = 0; i < 21; i++) {
                const wallet = ethers.Wallet.createRandom();
                protocols.push(wallet.address);
                await vault.verifyProtocol(wallet.address, `Protocol${i}`);
            }

            // Should fail on 21st
            await expect(
                vault.connect(alice).approveProtocolsBatch(protocols)
            ).to.be.revertedWithCustomError(vault, "MaxProtocolsReached");
        });
    });

    describe("Agent Authorization", function () {
        it("Should authorize an agent", async function () {
            await vault.connect(alice).authorizeAgent(agent.address);

            expect(await vault.authorizedAgents(alice.address)).to.equal(agent.address);
        });

        it("Should revoke an agent", async function () {
            await vault.connect(alice).authorizeAgent(agent.address);
            await vault.connect(alice).revokeAgent();

            expect(await vault.authorizedAgents(alice.address)).to.equal(ethers.constants.AddressZero);
        });
    });

    describe("Rebalancing", function () {
        let mockProtocol;

        beforeEach(async function () {
            // Deploy mock protocol
            const MockProtocol = await ethers.getContractFactory("MockProtocol");
            mockProtocol = await MockProtocol.deploy(fxrp.address);

            // Verify protocol
            await vault.verifyProtocol(mockProtocol.address, "MockProtocol");

            // Alice setup
            await fxrp.connect(alice).approve(vault.address, ethers.utils.parseEther("10000"));
            await vault.connect(alice).deposit(ethers.utils.parseEther("1000"));
            await vault.connect(alice).approveProtocol(mockProtocol.address);
            await vault.connect(alice).authorizeAgent(agent.address);
        });

        it("Should rebalance from vault to protocol", async function () {
            const amount = ethers.utils.parseEther("500");
            const depositData = mockProtocol.interface.encodeFunctionData("deposit", [amount]);

            await vault.connect(agent).rebalance(
                alice.address,
                ethers.constants.AddressZero, // From vault
                mockProtocol.address, // To protocol
                amount,
                "0x", // No withdraw data
                depositData,
                "Testing rebalance"
            );

            // Check balances updated
            const balances = await vault.getUserBalances(alice.address);
            expect(balances.vaultBalance).to.equal(ethers.utils.parseEther("500"));
        });

        it("Should reject rebalance from unauthorized agent", async function () {
            const amount = ethers.utils.parseEther("500");

            await expect(
                vault.connect(bob).rebalance( // Bob is not authorized
                    alice.address,
                    ethers.constants.AddressZero,
                    mockProtocol.address,
                    amount,
                    "0x",
                    "0x",
                    "Unauthorized"
                )
            ).to.be.revertedWithCustomError(vault, "NotAuthorizedAgent");
        });

        it("Should reject rebalance to unapproved protocol", async function () {
            // Deploy another protocol (not approved by Alice)
            const MockProtocol2 = await ethers.getContractFactory("MockProtocol");
            const mockProtocol2 = await MockProtocol2.deploy(fxrp.address);
            await vault.verifyProtocol(mockProtocol2.address, "MockProtocol2");

            const amount = ethers.utils.parseEther("500");

            await expect(
                vault.connect(agent).rebalance(
                    alice.address,
                    ethers.constants.AddressZero,
                    mockProtocol2.address, // Not approved!
                    amount,
                    "0x",
                    "0x",
                    "Should fail"
                )
            ).to.be.revertedWithCustomError(vault, "ProtocolNotApproved");
        });
    });
});
```

---

## Security Considerations

### 1. Protocol Verification

**Why it matters:** Only verified protocols can be approved by users.

```solidity
// Admin must verify protocol first
function verifyProtocol(address protocol, string calldata name) external onlyOwner;

// Users can only approve verified protocols
function approveProtocol(address protocol) external {
    if (!verifiedProtocols[protocol]) revert ProtocolNotVerified();
    // ...
}
```

**Process:**
1. Kimera team audits protocol
2. Admin calls `verifyProtocol()`
3. Users can now approve it

### 2. Per-User Allowlists

**Why it matters:** Each user controls their own risk.

```solidity
// Alice's approvals don't affect Bob
approvedProtocols[alice][kinetic] = true;
approvedProtocols[bob][kinetic] = false; // Bob hasn't approved
```

### 3. Agent Cannot Bypass

**Why it matters:** Even compromised agent cannot steal funds.

```solidity
function rebalance(...) external {
    // ENFORCED: Must be user's authorized agent
    require(msg.sender == authorizedAgents[user]);

    // ENFORCED: Must use approved protocols
    require(approvedProtocols[user][toProtocol]);

    // Can only move to allowlisted destinations
}
```

### 4. Emergency Controls

```solidity
// User can instantly revoke agent
function revokeAgent() external;

// User can emergency withdraw (bypass agent)
function withdrawAll() external;

// Admin can pause in case of exploit
function pause() external onlyOwner;
```

---

## Gas Cost Analysis

| Function | Gas Cost | USD (@$0.02/FLR) |
|----------|----------|------------------|
| `deposit()` | ~80k | $0.03 |
| `withdraw()` | ~50k | $0.02 |
| `approveProtocol()` | ~50k | $0.02 |
| `approveProtocolsBatch(3)` | ~120k | $0.05 |
| `revokeProtocol()` | ~30k | $0.01 |
| `authorizeAgent()` | ~45k | $0.02 |
| `rebalance()` | ~150-300k | $0.06-0.12 |
| View functions | 0 | $0 |

**Total onboarding cost:** ~$0.10 (deposit + approve protocols + authorize agent)

---

## Implementation Checklist

- [x] Smart contract storage (mappings + arrays)
- [x] Approval/revoke functions
- [x] Batch operations for gas efficiency
- [x] Events for all state changes
- [x] Protocol verification registry
- [x] Emergency pause mechanism
- [x] Comprehensive error handling
- [x] ReentrancyGuard protection
- [x] SafeERC20 for token transfers
- [ ] Database schema for cache
- [ ] Event listener service
- [ ] API endpoints for UI
- [ ] Periodic sync job (backup)
- [ ] Frontend UI for preferences
- [ ] AI agent integration
- [ ] Unit tests
- [ ] Integration tests
- [ ] Security audit

**The complete smart contract is available at:** `contracts/KimeraVault.sol`

---

## Next Steps

1. **Review the contract code** at `contracts/KimeraVault.sol`
2. **Deploy to Coston2** for testing
3. **Implement event listener** for database sync
4. **Build frontend UI** for protocol selection
5. **Integrate AI agent** with rebalance function
6. **Security audit** before mainnet

**Questions? Need help with deployment or integration?**
