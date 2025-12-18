# Kimera DeFAI Yield Agent

A decentralized AI-powered yield optimization agent for FXRP tokens on the Flare Network. Kimera uses ERC-4337 Smart Accounts and session keys to enable secure, automated yield farming across multiple DeFi protocols.

## Overview

Kimera is a DeFAI (Decentralized Finance + AI) proof-of-concept that addresses the complexity of yield optimization in DeFi. Users deposit FXRP tokens into a smart account, and an AI agent continuously monitors yields across protocols, automatically rebalancing positions to maximize returns while maintaining full user control.

### Key Features

- **Smart Account Architecture**: Built on ERC-4337 account abstraction for gasless and programmable transactions
- **Session Key Security**: AI agent operates with limited permissions via ERC-7579 session keys
- **Multi-Protocol Support**: Integrates with Kinetic, Firelight, and Vault X protocols on Flare
- **Automated Optimization**: Continuous yield monitoring and intelligent rebalancing
- **User Control**: Users retain full ownership and can revoke AI permissions anytime
- **Transparent Operations**: Real-time dashboard showing all rebalancing decisions and yields

## Architecture

The system consists of three main layers:

### 1. Smart Contract Layer (On-Chain)
- **ERC-4337 Smart Accounts**: User-controlled accounts with modular functionality
- **Session Key Module**: Enforces strict permissions for AI agent actions
- **Protocol Adapters**: Standardized interfaces to DeFi protocols
- **Account Factory**: Deploys new smart accounts for users

### 2. AI Agent Layer (Off-Chain)
- **Yield Data Ingestion**: Aggregates APY data from multiple sources
- **Strategy Engine**: Determines optimal allocation based on yields and user preferences
- **Transaction Executor**: Constructs and submits UserOperations via session keys
- **Monitoring Service**: Tracks portfolio performance and transaction status

### 3. Frontend Layer
- **React Dashboard**: User interface for deposits, configuration, and monitoring
- **Wallet Integration**: Supports BiFrost, MetaMask, and Luminite wallets
- **Real-time Updates**: WebSocket connection for live transaction notifications

## Security Model

### Permission Constraints

The AI agent's session key is restricted to:
- Depositing FXRP to whitelisted protocols only
- Withdrawing FXRP back to the user's smart account only
- Operating within a defined time window
- No arbitrary transfers or account modifications

### User Control

Users maintain complete control through:
- Full ownership via their EOA wallet
- Ability to revoke session keys instantly
- Direct withdrawal rights at any time
- Manual override of AI decisions

## Technology Stack

- **Smart Contracts**: Solidity 0.8.23+, Foundry
- **Account Abstraction**: ERC-4337 with Etherspot SDK
- **Off-Chain Agent**: Python 3.11+, FastAPI, Web3.py
- **Frontend**: Next.js 14, RainbowKit, Tailwind CSS
- **Infrastructure**: AWS (Lambda, RDS, Secrets Manager)
- **Blockchain**: Flare Network (Coston2 testnet)

## Documentation

For detailed technical specifications, architecture diagrams, and implementation details, see:

- [Architecture Review & Refinement](./architecture-review.md) - Comprehensive system design document

## Project Status

**Current Phase**: Architecture & Design (Phase 1 PoC)

**Timeline**: 7 weeks estimated development

**Budget**: $58k-72k (includes infrastructure validation, development, testing, and security review)

## Key Differentiators

1. **Security-First**: Session keys prevent arbitrary fund transfers
2. **User Sovereignty**: Non-custodial, user retains full control
3. **Gas Efficiency**: ERC-4337 enables optimized batched transactions
4. **Pragmatic Approach**: Centralized AI for PoC with clear path to decentralization
5. **Single Asset Focus**: FXRP-only reduces complexity and attack surface

## Next Steps

1. Validate ERC-4337 bundler infrastructure on Flare Coston2 testnet
2. Deploy smart contracts and session key module
3. Implement yield data ingestion and strategy engine
4. Build frontend dashboard and wallet integration
5. Conduct security review and testnet validation
6. Launch public beta on Coston2

## Risk Mitigation

- **ERC-4337 Availability**: Early validation on Coston2 with fallback to meta-transactions
- **Session Key Security**: Time-bounds, rotation policy, and circuit breaker mechanism
- **Protocol Risk**: Circuit breaker for anomaly detection and automatic pause
- **Gas Economics**: Net yield calculation includes gas costs to prevent negative rebalancing

## License

[To be determined]

## Contact

[Project contact information to be added]
