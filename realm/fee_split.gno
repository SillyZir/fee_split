package fee_split

import (
	"strconv"
	"strings"
)

// Split holds a fee-splitting configuration with percentage-based shares
// denominated in basis points (1 bp = 0.01%, 10000 bp = 100%).
type Split struct {
	Owner          string
	Recipients     []string
	Shares         []uint64 // basis points, must sum to 10000
	Balances       map[string]uint64
	TotalDeposited uint64
	TotalClaimed   uint64
	Frozen         bool
}

var (
	splits map[string]*Split
	nextID int
)

func init() {
	splits = make(map[string]*Split)
	nextID = 1
}

// ---------- helpers ----------

func formatPct(bp uint64) string {
	whole := strconv.FormatUint(bp/100, 10)
	frac := strconv.FormatUint(bp%100, 10)
	if len(frac) == 1 {
		frac = "0" + frac
	}
	return whole + "." + frac + "%"
}

func mustGetSplit(id string) *Split {
	s, ok := splits[id]
	if !ok {
		panic("split not found: " + id)
	}
	return s
}

func boolStr(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}

func parseBasisPoints(raw string) []uint64 {
	parts := strings.Split(raw, ",")
	out := make([]uint64, len(parts))
	var total uint64
	for i, s := range parts {
		v, err := strconv.Atoi(strings.TrimSpace(s))
		if err != nil || v <= 0 {
			panic("invalid share value: " + strings.TrimSpace(s))
		}
		out[i] = uint64(v)
		total += uint64(v)
	}
	if total != 10000 {
		panic("shares must sum to 10000 basis points, got " + strconv.FormatUint(total, 10))
	}
	return out
}

func parseAddresses(raw string) []string {
	parts := strings.Split(raw, ",")
	out := make([]string, len(parts))
	for i, r := range parts {
		addr := strings.TrimSpace(r)
		if addr == "" {
			panic("empty recipient address at position " + strconv.Itoa(i))
		}
		out[i] = addr
	}
	return out
}

// ---------- write operations ----------

// CreateSplit registers a new split. The caller-provided owner address
// controls future updates. Recipients and shares are comma-separated;
// shares are in basis points summing to 10000.
func CreateSplit(_ realm, owner, recipientList, shareList string) string {
	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)

	if len(recipients) != len(shares) {
		panic("recipients and shares must have the same length")
	}
	if len(recipients) == 0 {
		panic("at least one recipient is required")
	}

	seen := make(map[string]bool)
	for _, r := range recipients {
		if seen[r] {
			panic("duplicate recipient: " + r)
		}
		seen[r] = true
	}

	id := "split_" + strconv.Itoa(nextID)
	nextID++

	balances := make(map[string]uint64)
	for _, r := range recipients {
		balances[r] = 0
	}

	splits[id] = &Split{
		Owner:      owner,
		Recipients: recipients,
		Shares:     shares,
		Balances:   balances,
	}
	return id
}

// Deposit distributes amount across recipients proportionally.
// Rounding dust goes to the last recipient.
func Deposit(_ realm, splitID string, amount uint64) {
	s := mustGetSplit(splitID)
	if s.Frozen {
		panic("split is frozen")
	}
	if amount == 0 {
		panic("amount must be greater than zero")
	}

	s.TotalDeposited += amount

	var distributed uint64
	last := len(s.Recipients) - 1
	for i, r := range s.Recipients {
		var share uint64
		if i == last {
			share = amount - distributed
		} else {
			share = (amount * s.Shares[i]) / 10000
		}
		s.Balances[r] += share
		distributed += share
	}
}

// Claim withdraws the caller's accumulated balance.
func Claim(_ realm, splitID, caller string) uint64 {
	s := mustGetSplit(splitID)

	bal, exists := s.Balances[caller]
	if !exists {
		panic("not a recipient of this split")
	}
	if bal == 0 {
		panic("nothing to claim")
	}

	s.Balances[caller] = 0
	s.TotalClaimed += bal
	return bal
}

// UpdateShares replaces recipients and shares. Owner only. Not if frozen.
func UpdateShares(_ realm, splitID, caller, recipientList, shareList string) {
	s := mustGetSplit(splitID)
	if caller != s.Owner {
		panic("only the owner can update shares")
	}
	if s.Frozen {
		panic("split is frozen")
	}

	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)

	if len(recipients) != len(shares) {
		panic("recipients and shares must have the same length")
	}

	seen := make(map[string]bool)
	for _, r := range recipients {
		if seen[r] {
			panic("duplicate recipient: " + r)
		}
		seen[r] = true
	}

	for _, r := range recipients {
		if _, ok := s.Balances[r]; !ok {
			s.Balances[r] = 0
		}
	}

	s.Recipients = recipients
	s.Shares = shares
}

// TransferOwnership hands control to a new owner.
func TransferOwnership(_ realm, splitID, caller, newOwner string) {
	s := mustGetSplit(splitID)
	if caller != s.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		panic("new owner must not be empty")
	}
	s.Owner = newOwner
}

// Freeze permanently locks shares. One-way, cannot be undone.
func Freeze(_ realm, splitID, caller string) {
	s := mustGetSplit(splitID)
	if caller != s.Owner {
		panic("only the owner can freeze")
	}
	s.Frozen = true
}

// ---------- read-only queries ----------

// GetSplitInfo returns a human-readable summary.
func GetSplitInfo(splitID string) string {
	s := mustGetSplit(splitID)

	var b strings.Builder
	b.WriteString("Split: " + splitID + "\n")
	b.WriteString("Owner: " + s.Owner + "\n")
	b.WriteString("Frozen: " + boolStr(s.Frozen) + "\n")
	b.WriteString("Total deposited: " + strconv.FormatUint(s.TotalDeposited, 10) + "\n")
	b.WriteString("Total claimed: " + strconv.FormatUint(s.TotalClaimed, 10) + "\n")
	b.WriteString("Recipients:\n")
	for i, r := range s.Recipients {
		b.WriteString("  " + r + "  " + formatPct(s.Shares[i]) + "  claimable: " + strconv.FormatUint(s.Balances[r], 10) + "\n")
	}
	return b.String()
}

// GetClaimable returns claimable balance for an address.
func GetClaimable(splitID, addr string) uint64 {
	s := mustGetSplit(splitID)
	return s.Balances[addr]
}

// ---------- render ----------

// Render returns a markdown overview. Never panics.
func Render(path string) string {
	if splits == nil || len(splits) == 0 {
		return "# Fee Split\n\nNo active splits.\n"
	}

	var b strings.Builder
	b.WriteString("# Fee Split\n\n")

	for id, s := range splits {
		b.WriteString("## " + id + "\n\n")
		if s == nil {
			b.WriteString("_(invalid)_\n\n")
			continue
		}
		b.WriteString("```\n")
		b.WriteString("Owner: " + s.Owner + "\n")
		b.WriteString("Frozen: " + boolStr(s.Frozen) + "\n")
		b.WriteString("Total deposited: " + strconv.FormatUint(s.TotalDeposited, 10) + "\n")
		b.WriteString("Total claimed: " + strconv.FormatUint(s.TotalClaimed, 10) + "\n")
		if len(s.Recipients) > 0 {
			b.WriteString("Recipients:\n")
			for i, r := range s.Recipients {
				share := "??%"
				if i < len(s.Shares) {
					share = formatPct(s.Shares[i])
				}
				bal := "0"
				if s.Balances != nil {
					bal = strconv.FormatUint(s.Balances[r], 10)
				}
				b.WriteString("  " + r + "  " + share + "  claimable: " + bal + "\n")
			}
		}
		b.WriteString("```\n\n")
	}
	return b.String()
}
