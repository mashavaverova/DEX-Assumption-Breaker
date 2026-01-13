# DEX-Assumption-Breaker


## What is this?
A security-focused test lab that demonstrates how common integration assumptions
break when Uniswap V2 interacts with non-standard ERC20 tokens
(e.g. fee-on-transfer tokens or direct balance donations).

This repository is **not** about vulnerabilities in Uniswap,
but about **developer-side assumptions that silently fail**.


## Why this repository exists

Many DeFi integrations assume that:

- `amountIn` === tokens actually received by the pair
- `getAmountsOut()` reflects the real output of a swap
- ERC20 balances and AMM reserves always stay in sync

These assumptions hold only for *well-behaved tokens*.

This repository demonstrates — with executable tests —
why these assumptions **do not hold** in the presence of:
- fee-on-transfer tokens
- direct token donations to AMM pairs
- exact-out swap logic built on optimistic quotes

## Non-goals

This repository does NOT:
- claim vulnerabilities in Uniswap V2
- attempt to exploit Uniswap or LPs
- propose protocol-level fixes
- replace Uniswap audits

Uniswap V2 behaves exactly as designed.

The risks shown here appear **only when integrators make assumptions**
that the protocol never promised.

## Threat model (simplified)

Actor: application developer or protocol integrator  
Surface: interaction with Uniswap V2 pairs or routers  
Risk: incorrect pricing, revert risk, user loss, accounting drift

We assume:
- attacker may deploy non-standard ERC20 tokens
- users or third parties may transfer tokens directly to pairs
- integrator relies on quotes without verifying actual transfers


## Scenario 1 — Fee-on-transfer breaks quote assumptions

A fee-on-transfer token deducts a percentage during `transfer()`.

Effect:
- Pair receives fewer tokens than `amountIn`
- `getAmountsOut(amountIn)` assumes full transfer
- Actual output is lower than quoted output

Tests show:
- `actualIn < amountIn`
- `actualOut < quotedOut`
- "exact-out" logic becomes unsafe or optimistic
Relevant tests:
- test_fee_math_actualIn_equals_amountIn_minus_fee
- test_quote_assumption_breaks_actualOut_is_lower
- test_naive_swap_using_quotedOut_is_unsafe_or_overly_optimistic

## Scenario 2 — Balances can diverge from reserves

Uniswap V2 tracks liquidity using **internal reserves**, not raw ERC20 balances.

If tokens are transferred directly to the pair:
- ERC20 balance increases
- reserves remain unchanged
- price math continues to use old reserves

Consequences:
- quotes look "wrong"
- arbitrage or `sync()` is required
- extra tokens can be skimmed by anyone
Relevant tests:
- test_donation_to_pair_makes_balance_diff_from_reserves
- test_donation_can_be_extracted_with_skim


## Why custom tokens are used

Custom ERC20 implementations are used intentionally.

Reason:
- to make fee logic explicit
- to avoid hiding behavior behind library abstractions
- to keep the lab readable and auditable

This repository focuses on **mechanics**, not production-ready token code.


## Running the tests

Requirements:
- Foundry

Install dependencies:
```bash
forge install

after that use 

forge test -vv

## Possible extensions (do it later)

- Rebase token behavior
- ERC777-style callback pressure
- Invariant fuzzing
- Formal verification of quote monotonicity



