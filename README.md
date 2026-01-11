# DEX-Assumption-Breaker
Small security-focused experiments demonstrating how common assumptions in Uniswap v2-style tooling break under non-standard ERC20 behaviors (fee-on-transfer, etc).

## What is this?
A security lab exploring hidden assumptions in Uniswap v2-style DEX flows.

This repo intentionally avoids Router02 in some cases to demonstrate where
assumptions about CREATE2, token behavior, and transfer semantics break down.

## Current focus
- Fee-on-transfer tokens
- Router quote vs actual execution mismatch
- Pair-level behavior vs Router-level abstractions

## Status
🧪 Experimental / WIP  
This repo is intentionally kept as a living lab. Expect refactors.

## Why this exists
Audits often fail not because code is wrong, but because assumptions are invisible.
This repo makes those assumptions explicit.
