# fee_split — Technical Specification

## Overview

`fee_split` is a Gno realm that manages percentage-based revenue splitting between multiple recipients. It provides a pull-based claim model where deposited funds are allocated proportionally and recipients withdraw at their discretion.

## Data Model

### Split

```
type Split struct {
    Owner          string
    Recipients     []string
    Shares         []uint64              // basis points, sum = 10000
    Balances       map[string]uint64
    TotalDeposited uint64
    TotalClaimed   uint64
    Frozen         bool
}
```

Note: `Owner`, `Recipients`, and `Balances` keys use plain `string` rather than `std.Address`. The consuming realm is responsible for passing valid address strings.

- **Shares** are in basis points: 1 bp = 0.01%, 10000 bp = 100%.
- **Balances** track per-recipient claimable amounts.
- **Frozen** is a one-way flag — once set, shares cannot be changed.

### Storage

Splits are stored in a package-level `map[string]*Split` keyed by auto-incrementing IDs (`split_1`, `split_2`, ...).

## Invariants

1. `sum(Shares) == 10000` — enforced on create and update.
2. `len(Recipients) == len(Shares)` — always.
3. `len(Recipients) >= 1` — at least one recipient.
4. No duplicate recipients within a single split.
5. `TotalDeposited >= TotalClaimed + sum(Balances)` — no value created from nothing.
6. Once `Frozen == true`, `UpdateShares` is permanently disabled.

## Authorization

Unlike other realms in this stack, `fee_split` uses **explicit caller string parameters** rather than `std.PreviousRealm().Address()` for authorization. The `owner` is stored at creation time and compared against the `caller` string passed to each write operation. The consuming realm is responsible for supplying the correct address.

| Operation | Required `caller` |
|-----------|-------------------|
| CreateSplit | Anyone — provided `owner` string is stored as controller |
| Deposit | Anyone — no ownership check |
| Claim | `caller` must be a recipient with balance > 0 |
| UpdateShares | `caller` must equal stored owner; split must not be frozen |
| TransferOwnership | `caller` must equal stored owner |
| Freeze | `caller` must equal stored owner |

## Rounding

Integer division of `(amount * share) / 10000` can lose fractional units. The last recipient in the list receives `amount - sum(all_other_shares)` to ensure the full deposit is distributed with zero dust loss.

## Deposit Flow

```
1. Validate split exists and is not frozen
2. Validate amount > 0
3. Increment TotalDeposited
4. For each recipient except last:
     allocation = (amount * share) / 10000
     balance[recipient] += allocation
     distributed += allocation
5. Last recipient:
     balance[last] += amount - distributed
```

## Claim Flow

```
1. Validate split exists
2. Validate caller string is a registered recipient
3. Validate balance[caller] > 0
4. Set balance[caller] = 0
5. Increment TotalClaimed
6. Return claimed amount
```

## Freeze Semantics

Freezing is designed for the common pattern where a team agrees on shares upfront and wants to guarantee they cannot be changed later. After freezing:

- `UpdateShares` → panic
- `Deposit` → works normally
- `Claim` → works normally
- `TransferOwnership` → still works (ownership is operational, not share-related)

## Limitations

- No on-chain token transfer on claim — the realm tracks accounting only. Integration with a token realm (e.g., wrapping with `banker`) is left to the deployer.
- Split IDs are sequential integers, not caller-namespaced. Any caller can deposit to any split.
- No event emission — callers must query state to observe changes.
