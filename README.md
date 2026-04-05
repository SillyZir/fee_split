`Gno.land` · `Smart Contracts` · `Infrastructure`

# fee_split

Trustless, on-chain revenue splitting for Gno.land.

## Problem

Every team that earns on-chain revenue — DAOs collecting protocol fees, freelancer collectives invoicing clients, validator teams pooling rewards — faces the same question: *who distributes the money, and why should anyone trust them?*

Manual distribution is slow, error-prone, and requires trusting a single treasurer. Off-chain spreadsheets don't enforce anything. Existing multisig solutions are built for approval workflows, not for continuous revenue sharing.

## How it works

`fee_split` is a Gno realm that lets anyone create a **split** — a set of recipients with percentage-based shares that must sum to exactly 100%.

1. **Create** a split with recipients and their shares (in basis points: 5000 = 50%)
2. **Deposit** funds into the split — they're instantly allocated proportionally
3. **Recipients claim** their balance at any time — no approval needed
4. **Owner updates** shares if the team changes — unclaimed balances are preserved
5. **Freeze** the split to make shares permanent and immutable

Shares are denominated in basis points (1 bp = 0.01%) for precision without floating point. Rounding dust from integer division is assigned to the last recipient so no value is silently lost.

## Why this approach

| Approach | Problem |
|----------|---------|
| Manual distribution | Trust required, slow, error-prone |
| Multisig wallet | Built for approvals, not continuous splitting |
| Off-chain agreements | Not enforceable |
| **fee_split** | **Automatic, trustless, verifiable, immutable when frozen** |

The key design choice: splits are **pull-based** (recipients claim) rather than push-based (auto-send). This avoids failed transfers blocking the entire split and gives recipients control over when they withdraw.

## Usage

### Create a split

```
// 60% to alice, 25% to bob, 15% to carol
// owner is the address that controls the split
CreateSplit(
    cross,
    "g1owner...",
    "g1alice...,g1bob...,g1carol...",
    "6000,2500,1500"
)
// returns: "split_1"
```

### Deposit funds

```
Deposit(cross, "split_1", 1000000)
// alice gets 600000, bob gets 250000, carol gets 150000
```

### Claim your share

```
Claim(cross, "split_1", "g1alice...")
// returns: your claimable balance
```

### Update shares (owner only)

```
UpdateShares(cross, "split_1", "g1owner...", "g1alice...,g1bob...,g1dave...", "5000,3000,2000")
```

### Freeze shares permanently

```
Freeze(cross, "split_1", "g1owner...")
// shares can never be changed again
```

### Query a split

```
GetSplitInfo("split_1")
GetClaimable("split_1", "g1alice...")
```

## API

| Function | Access | Description |
|----------|--------|-------------|
| `CreateSplit(cross, owner, recipients, shares)` | Anyone | Create a new split. Provided `owner` string controls it. |
| `Deposit(cross, splitID, amount)` | Anyone | Distribute funds to recipients. |
| `Claim(cross, splitID, caller)` | Recipient | Withdraw accumulated balance for `caller`. |
| `UpdateShares(cross, splitID, caller, recipients, shares)` | Owner | Change recipients and shares. `caller` must match owner. |
| `TransferOwnership(cross, splitID, caller, newOwner)` | Owner | Hand off split control. `caller` must match owner. |
| `Freeze(cross, splitID, caller)` | Owner | Permanently lock shares. `caller` must match owner. |
| `GetSplitInfo(splitID)` | Anyone | View split configuration and balances. |
| `GetClaimable(splitID, addr)` | Anyone | Check claimable balance for an address. |
| `Render(path)` | Anyone | Markdown overview of all splits. |

## Safety

- **Percentage validation**: shares must sum to exactly 10000 basis points (100%)
- **Duplicate detection**: rejects duplicate recipients in the same split
- **Explicit caller**: owner and caller are passed as plain string parameters — the consuming realm is responsible for passing the correct address (typically derived from `std.PreviousRealm().Address()` in the caller's context)
- **Rounding protection**: dust from integer division goes to the last recipient
- **Freeze mechanism**: one-way lock prevents owner from changing shares after trust is established
- **Balance preservation**: updating shares never destroys unclaimed balances

## Query on Gno.land

```
gnokey query vm/qeval --data 'gno.land/r/fee_split.GetSplitInfo("split_1")' --remote <rpc>
gnokey query vm/qeval --data 'gno.land/r/fee_split.GetClaimable("split_1", "g1alice...")' --remote <rpc>
```

Visit `/r/fee_split` on a Gno.land node to see all active splits with their configuration and balances.

## Stack

- [Gno](https://gno.land) — Go-like smart contract language
- [Gno.land](https://gno.land) — Layer 1 blockchain

## Part of the Gno Infrastructure Stack

| Realm | Layer |
|-------|-------|
| **fee_split** | **Revenue & value flow** |
| [permission_registry](https://github.com/SillyZir/permission_registry) | Access control |
| [service_registry](https://github.com/SillyZir/service_registry) | Discovery |
| [upgrade_registry](https://github.com/SillyZir/upgrade_registry) | Upgrade tracking |
| [timelock_guardian](https://github.com/SillyZir/timelock_guardian) | Security |

---
