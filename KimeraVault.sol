// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title KimeraVault
 * @notice Non-custodial vault for AI-powered yield optimization on Flare
 * @dev Users maintain full control, AI agent can only rebalance within approved protocols
 */
contract KimeraVault is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice The FXRP token contract
    IERC20 public immutable FXRP;

    /// @notice Minimum deposit amount (prevents dust)
    uint256 public constant MIN_DEPOSIT = 1e18; // 1 FXRP

    /// @notice Maximum number of protocols a user can approve
    uint256 public constant MAX_PROTOCOLS_PER_USER = 20;

    // ============================================
    // USER DATA STORAGE
    // ============================================

    /// @notice User's total FXRP balance in the vault
    mapping(address => uint256) public balances;

    /// @notice User's authorized AI agent address
    mapping(address => address) public authorizedAgents;

    /// @notice User => protocol address => is approved
    mapping(address => mapping(address => bool)) public approvedProtocols;

    /// @notice User => array of approved protocol addresses (for enumeration)
    mapping(address => address[]) private userProtocolList;

    /// @notice User => protocol => index in userProtocolList array
    mapping(address => mapping(address => uint256)) private protocolIndex;

    /// @notice Tracks which protocols a user has funds deposited in
    /// @dev User => protocol => deposited amount
    mapping(address => mapping(address => uint256)) public userProtocolBalances;

    // ============================================
    // PROTOCOL REGISTRY
    // ============================================

    /// @notice Global registry of verified protocols
    mapping(address => bool) public verifiedProtocols;

    /// @notice List of all verified protocols
    address[] public verifiedProtocolList;

    // ============================================
    // EVENTS
    // ============================================

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event AgentAuthorized(address indexed user, address indexed agent);
    event AgentRevoked(address indexed user);
    event ProtocolApproved(address indexed user, address indexed protocol);
    event ProtocolRevoked(address indexed user, address indexed protocol);
    event Rebalanced(
        address indexed user,
        address indexed fromProtocol,
        address indexed toProtocol,
        uint256 amount,
        string reason
    );
    event ProtocolVerified(address indexed protocol, string name);
    event ProtocolUnverified(address indexed protocol);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    // ============================================
    // ERRORS
    // ============================================

    error InvalidAmount();
    error InvalidProtocol();
    error InsufficientBalance();
    error ProtocolNotApproved();
    error ProtocolNotVerified();
    error ProtocolAlreadyApproved();
    error ProtocolNotInList();
    error NotAuthorizedAgent();
    error AgentNotSet();
    error MaxProtocolsReached();
    error RebalanceFailed(string reason);

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /**
     * @notice Initialize the vault with FXRP token
     * @param _fxrp Address of the FXRP token contract
     */
    constructor(address _fxrp) {
        if (_fxrp == address(0)) revert InvalidProtocol();
        FXRP = IERC20(_fxrp);
    }

    // ============================================
    // USER FUNCTIONS - DEPOSITS & WITHDRAWALS
    // ============================================

    /**
     * @notice Deposit FXRP into the vault
     * @param amount Amount of FXRP to deposit
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount < MIN_DEPOSIT) revert InvalidAmount();

        FXRP.safeTransferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;

        emit Deposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw FXRP from the vault to user's wallet
     * @param amount Amount of FXRP to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (balances[msg.sender] < amount) revert InsufficientBalance();

        balances[msg.sender] -= amount;
        FXRP.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Withdraw all FXRP from vault (emergency function)
     * @dev Withdraws from vault balance only, not from protocols
     */
    function withdrawAll() external nonReentrant {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert InsufficientBalance();

        balances[msg.sender] = 0;
        FXRP.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, amount);
    }

    // ============================================
    // USER FUNCTIONS - AGENT MANAGEMENT
    // ============================================

    /**
     * @notice Authorize an AI agent to manage user's funds
     * @param agent Address of the AI agent
     */
    function authorizeAgent(address agent) external {
        if (agent == address(0)) revert InvalidProtocol();

        authorizedAgents[msg.sender] = agent;
        emit AgentAuthorized(msg.sender, agent);
    }

    /**
     * @notice Revoke AI agent's authorization
     */
    function revokeAgent() external {
        delete authorizedAgents[msg.sender];
        emit AgentRevoked(msg.sender);
    }

    // ============================================
    // USER FUNCTIONS - PROTOCOL MANAGEMENT
    // ============================================

    /**
     * @notice Approve a protocol for AI agent to use
     * @param protocol Address of the protocol contract
     */
    function approveProtocol(address protocol) external {
        if (protocol == address(0)) revert InvalidProtocol();
        if (!verifiedProtocols[protocol]) revert ProtocolNotVerified();
        if (approvedProtocols[msg.sender][protocol]) revert ProtocolAlreadyApproved();
        if (userProtocolList[msg.sender].length >= MAX_PROTOCOLS_PER_USER) {
            revert MaxProtocolsReached();
        }

        approvedProtocols[msg.sender][protocol] = true;
        protocolIndex[msg.sender][protocol] = userProtocolList[msg.sender].length;
        userProtocolList[msg.sender].push(protocol);

        emit ProtocolApproved(msg.sender, protocol);
    }

    /**
     * @notice Approve multiple protocols at once (gas optimization)
     * @param protocols Array of protocol addresses
     */
    function approveProtocolsBatch(address[] calldata protocols) external {
        uint256 currentCount = userProtocolList[msg.sender].length;
        if (currentCount + protocols.length > MAX_PROTOCOLS_PER_USER) {
            revert MaxProtocolsReached();
        }

        for (uint256 i = 0; i < protocols.length; i++) {
            address protocol = protocols[i];

            if (protocol == address(0)) revert InvalidProtocol();
            if (!verifiedProtocols[protocol]) revert ProtocolNotVerified();

            // Skip if already approved
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
        if (!approvedProtocols[msg.sender][protocol]) revert ProtocolNotInList();

        // Check that user has no funds in this protocol
        if (userProtocolBalances[msg.sender][protocol] > 0) {
            revert RebalanceFailed("Withdraw funds from protocol first");
        }

        approvedProtocols[msg.sender][protocol] = false;

        // Remove from array (swap with last element and pop)
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
     * @notice Revoke all approved protocols at once
     */
    function revokeAllProtocols() external {
        address[] memory protocols = userProtocolList[msg.sender];

        for (uint256 i = 0; i < protocols.length; i++) {
            address protocol = protocols[i];

            // Check no funds in protocol
            if (userProtocolBalances[msg.sender][protocol] > 0) {
                revert RebalanceFailed("Withdraw funds from all protocols first");
            }

            approvedProtocols[msg.sender][protocol] = false;
            emit ProtocolRevoked(msg.sender, protocol);
        }

        delete userProtocolList[msg.sender];
    }

    // ============================================
    // AI AGENT FUNCTIONS
    // ============================================

    /**
     * @notice Rebalance user funds between protocols
     * @param user User whose funds to rebalance
     * @param fromProtocol Protocol to withdraw from (address(0) = vault)
     * @param toProtocol Protocol to deposit to (address(0) = vault)
     * @param amount Amount of FXRP to move
     * @param withdrawData Calldata for withdrawal (if fromProtocol != address(0))
     * @param depositData Calldata for deposit (if toProtocol != address(0))
     * @param reason Human-readable reason for rebalancing
     */
    function rebalance(
        address user,
        address fromProtocol,
        address toProtocol,
        uint256 amount,
        bytes calldata withdrawData,
        bytes calldata depositData,
        string calldata reason
    ) external nonReentrant whenNotPaused {
        // 1. Validate caller is authorized agent
        if (msg.sender != authorizedAgents[user]) revert NotAuthorizedAgent();
        if (amount == 0) revert InvalidAmount();

        // 2. Validate protocols are approved (or vault)
        if (fromProtocol != address(0) && !approvedProtocols[user][fromProtocol]) {
            revert ProtocolNotApproved();
        }
        if (toProtocol != address(0) && !approvedProtocols[user][toProtocol]) {
            revert ProtocolNotApproved();
        }

        // 3. Validate user has sufficient balance
        if (balances[user] < amount) revert InsufficientBalance();

        // 4. Execute withdrawal from source protocol
        if (fromProtocol != address(0)) {
            // Withdraw from external protocol
            (bool success, bytes memory result) = fromProtocol.call(withdrawData);
            if (!success) {
                revert RebalanceFailed(_getRevertMsg(result));
            }

            // Update tracking
            if (userProtocolBalances[user][fromProtocol] >= amount) {
                userProtocolBalances[user][fromProtocol] -= amount;
            } else {
                userProtocolBalances[user][fromProtocol] = 0;
            }
        }
        // If fromProtocol == address(0), funds are already in vault

        // 5. Execute deposit to target protocol
        if (toProtocol != address(0)) {
            // Approve protocol to spend FXRP
            FXRP.safeApprove(toProtocol, 0); // Reset approval
            FXRP.safeApprove(toProtocol, amount);

            // Deposit to external protocol
            (bool success, bytes memory result) = toProtocol.call(depositData);
            if (!success) {
                revert RebalanceFailed(_getRevertMsg(result));
            }

            // Update tracking
            userProtocolBalances[user][toProtocol] += amount;

            // Reset approval
            FXRP.safeApprove(toProtocol, 0);
        }
        // If toProtocol == address(0), funds stay in vault

        emit Rebalanced(user, fromProtocol, toProtocol, amount, reason);
    }

    /**
     * @notice Batch rebalance multiple users
     * @param users Array of user addresses
     * @param fromProtocols Array of source protocols
     * @param toProtocols Array of target protocols
     * @param amounts Array of amounts
     * @param withdrawDataArray Array of withdrawal calldatas
     * @param depositDataArray Array of deposit calldatas
     * @param reasons Array of reasons
     */
    function rebalanceBatch(
        address[] calldata users,
        address[] calldata fromProtocols,
        address[] calldata toProtocols,
        uint256[] calldata amounts,
        bytes[] calldata withdrawDataArray,
        bytes[] calldata depositDataArray,
        string[] calldata reasons
    ) external nonReentrant whenNotPaused {
        uint256 length = users.length;
        if (
            length != fromProtocols.length ||
            length != toProtocols.length ||
            length != amounts.length ||
            length != withdrawDataArray.length ||
            length != depositDataArray.length ||
            length != reasons.length
        ) {
            revert InvalidAmount();
        }

        for (uint256 i = 0; i < length; i++) {
            // Validate agent authorization for each user
            if (msg.sender != authorizedAgents[users[i]]) {
                continue; // Skip unauthorized
            }

            // Execute individual rebalance
            _rebalanceInternal(
                users[i],
                fromProtocols[i],
                toProtocols[i],
                amounts[i],
                withdrawDataArray[i],
                depositDataArray[i],
                reasons[i]
            );
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Get user's approved protocols
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

    /**
     * @notice Get user's balance across all protocols
     * @param user User address
     * @return vaultBalance Balance in vault
     * @return protocolBalances Array of balances per protocol
     * @return totalBalance Total balance across vault + protocols
     */
    function getUserBalances(address user)
        external
        view
        returns (
            uint256 vaultBalance,
            uint256[] memory protocolBalances,
            uint256 totalBalance
        )
    {
        vaultBalance = balances[user];
        totalBalance = vaultBalance;

        address[] memory protocols = userProtocolList[user];
        protocolBalances = new uint256[](protocols.length);

        for (uint256 i = 0; i < protocols.length; i++) {
            protocolBalances[i] = userProtocolBalances[user][protocols[i]];
            totalBalance += protocolBalances[i];
        }
    }

    /**
     * @notice Get all verified protocols
     * @return Array of verified protocol addresses
     */
    function getVerifiedProtocols() external view returns (address[] memory) {
        return verifiedProtocolList;
    }

    /**
     * @notice Get user's agent authorization status
     * @param user User address
     * @return agent Address of authorized agent (address(0) if none)
     * @return isAuthorized True if agent is set
     */
    function getAgentStatus(address user)
        external
        view
        returns (address agent, bool isAuthorized)
    {
        agent = authorizedAgents[user];
        isAuthorized = agent != address(0);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /**
     * @notice Add a protocol to the verified registry
     * @param protocol Protocol address
     * @param name Protocol name
     */
    function verifyProtocol(address protocol, string calldata name) external onlyOwner {
        if (protocol == address(0)) revert InvalidProtocol();
        if (verifiedProtocols[protocol]) return; // Already verified

        verifiedProtocols[protocol] = true;
        verifiedProtocolList.push(protocol);

        emit ProtocolVerified(protocol, name);
    }

    /**
     * @notice Remove a protocol from verified registry
     * @param protocol Protocol address
     * @dev Use with caution - users with this protocol approved should revoke it
     */
    function unverifyProtocol(address protocol) external onlyOwner {
        if (!verifiedProtocols[protocol]) revert ProtocolNotVerified();

        verifiedProtocols[protocol] = false;

        // Remove from array
        for (uint256 i = 0; i < verifiedProtocolList.length; i++) {
            if (verifiedProtocolList[i] == protocol) {
                verifiedProtocolList[i] = verifiedProtocolList[verifiedProtocolList.length - 1];
                verifiedProtocolList.pop();
                break;
            }
        }

        emit ProtocolUnverified(protocol);
    }

    /**
     * @notice Pause the contract (emergency)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Internal rebalance logic (for batch operations)
     */
    function _rebalanceInternal(
        address user,
        address fromProtocol,
        address toProtocol,
        uint256 amount,
        bytes calldata withdrawData,
        bytes calldata depositData,
        string calldata reason
    ) private {
        if (amount == 0) return;

        // Validate protocols
        if (fromProtocol != address(0) && !approvedProtocols[user][fromProtocol]) {
            return; // Skip
        }
        if (toProtocol != address(0) && !approvedProtocols[user][toProtocol]) {
            return; // Skip
        }

        // Validate balance
        if (balances[user] < amount) return; // Skip

        // Execute withdrawal
        if (fromProtocol != address(0)) {
            (bool success, ) = fromProtocol.call(withdrawData);
            if (success) {
                if (userProtocolBalances[user][fromProtocol] >= amount) {
                    userProtocolBalances[user][fromProtocol] -= amount;
                } else {
                    userProtocolBalances[user][fromProtocol] = 0;
                }
            } else {
                return; // Skip on failure
            }
        }

        // Execute deposit
        if (toProtocol != address(0)) {
            FXRP.safeApprove(toProtocol, 0);
            FXRP.safeApprove(toProtocol, amount);

            (bool success, ) = toProtocol.call(depositData);
            if (success) {
                userProtocolBalances[user][toProtocol] += amount;
            }

            FXRP.safeApprove(toProtocol, 0);

            if (!success) return; // Skip on failure
        }

        emit Rebalanced(user, fromProtocol, toProtocol, amount, reason);
    }

    /**
     * @notice Extract revert message from failed call
     */
    function _getRevertMsg(bytes memory returnData) private pure returns (string memory) {
        // If the returnData length is less than 68, then the transaction failed silently
        if (returnData.length < 68) return "Transaction reverted silently";

        assembly {
            // Slice the sighash
            returnData := add(returnData, 0x04)
        }
        return abi.decode(returnData, (string)); // All that remains is the revert string
    }
}
