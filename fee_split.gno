package fee_split

import (
	"std"
	"strings"
	"strconv"

	ufmt "gno.land/p/nt/ufmt/v0"
)

// Split holds a fee-splitting configuration with percentage-based shares
// denominated in basis points (1 bp = 0.01%, 10000 bp = 100%).
type Split struct {
	Owner          std.Address
	Recipients     []std.Address
	Shares         []uint64 // basis points, must sum to 10000
	Balances       map[std.Address]uint64
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

// caller returns the address of the external caller (EOA), not an
// intermediate realm. This prevents contracts from impersonating users.
func caller() std.Address {
	return std.PreviousRealm().Address()
}

// parseBasisPoints converts a comma-separated string of integers into
// a validated slice of basis points. Panics if any value is zero,
// negative, non-numeric, or the total does not equal 10000.
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
		panic(ufmt.Sprintf("shares must sum to 10000 basis points, got %d", total))
	}
	return out
}

// parseAddresses splits a comma-separated address list, trims whitespace,
// and validates that no entry is empty. Returns the cleaned slice.
func parseAddresses(raw string) []std.Address {
	parts := strings.Split(raw, ",")
	out := make([]std.Address, len(parts))
	for i, r := range parts {
		addr := std.Address(strings.TrimSpace(r))
		if addr == "" {
			panic("empty recipient address at position " + strconv.Itoa(i))
		}
		out[i] = addr
	}
	return out
}

// ---------- public API ----------

// CreateSplit registers a new split configuration. The caller becomes
// the owner. Recipients and shares are comma-separated; shares are in
// basis points and must sum to exactly 10000.
func CreateSplit(cross realm, recipientList, shareList string) string {
	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)

	if len(recipients) != len(shares) {
		panic("recipients and shares must have the same length")
	}
	if len(recipients) == 0 {
		panic("at least one recipient is required")
	}

	// Reject duplicate recipients.
	seen := make(map[std.Address]bool)
	for _, r := range recipients {
		if seen[r] {
			panic("duplicate recipient: " + string(r))
		}
		seen[r] = true
	}

	id := ufmt.Sprintf("split_%d", nextID)
	nextID++

	balances := make(map[std.Address]uint64)
	for _, r := range recipients {
		balances[r] = 0
	}

	splits[id] = &Split{
		Owner:      caller(),
		Recipients: recipients,
		Shares:     shares,
		Balances:   balances,
	}
	return id
}

// Deposit distributes `amount` across a split's recipients in proportion
// to their shares. Rounding dust is assigned to the last recipient so
// that no value is silently lost.
func Deposit(cross realm, splitID string, amount uint64) {
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
			share = amount - distributed // remainder goes to last
		} else {
			share = (amount * s.Shares[i]) / 10000
		}
		s.Balances[r] += share
		distributed += share
	}
}

// Claim withdraws the caller's accumulated balance from a split.
// Returns the amount claimed.
func Claim(cross realm, splitID string) uint64 {
	c := caller()
	s := mustGetSplit(splitID)

	bal, exists := s.Balances[c]
	if !exists {
		panic("you are not a recipient of this split")
	}
	if bal == 0 {
		panic("nothing to claim")
	}

	s.Balances[c] = 0
	s.TotalClaimed += bal
	return bal
}

// UpdateShares replaces the recipient list and share distribution.
// Only the owner may call this. The split must not be frozen.
// Unclaimed balances for existing recipients are preserved.
func UpdateShares(cross realm, splitID, recipientList, shareList string) {
	c := caller()
	s := mustGetSplit(splitID)

	if c != s.Owner {
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

	seen := make(map[std.Address]bool)
	for _, r := range recipients {
		if seen[r] {
			panic("duplicate recipient: " + string(r))
		}
		seen[r] = true
	}

	// Preserve existing balances; initialise new recipients to zero.
	for _, r := range recipients {
		if _, ok := s.Balances[r]; !ok {
			s.Balances[r] = 0
		}
	}

	s.Recipients = recipients
	s.Shares = shares
}

// TransferOwnership hands control of the split to a new owner.
// Only the current owner may call this.
func TransferOwnership(cross realm, splitID string, newOwner std.Address) {
	c := caller()
	s := mustGetSplit(splitID)

	if c != s.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		panic("new owner address must not be empty")
	}
	s.Owner = newOwner
}

// Freeze permanently locks a split so that its shares can never be
// changed again. Deposits and claims continue to work normally. This
// is a one-way operation and cannot be undone.
func Freeze(cross realm, splitID string) {
	c := caller()
	s := mustGetSplit(splitID)

	if c != s.Owner {
		panic("only the owner can freeze the split")
	}
	s.Frozen = true
}

// ---------- read-only queries ----------

// GetSplitInfo returns a human-readable summary of a split.
func GetSplitInfo(splitID string) string {
	s := mustGetSplit(splitID)

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("Split: %s\n", splitID))
	b.WriteString(ufmt.Sprintf("Owner: %s\n", string(s.Owner)))
	b.WriteString(ufmt.Sprintf("Frozen: %s\n", boolStr(s.Frozen)))
	b.WriteString(ufmt.Sprintf("Total deposited: %d\n", s.TotalDeposited))
	b.WriteString(ufmt.Sprintf("Total claimed: %d\n", s.TotalClaimed))
	b.WriteString("Recipients:\n")
	for i, r := range s.Recipients {
		pct := ufmt.Sprintf("%d.%02d%%", s.Shares[i]/100, s.Shares[i]%100)
		b.WriteString(ufmt.Sprintf("  %s  %s  claimable: %d\n", string(r), pct, s.Balances[r]))
	}
	return b.String()
}

// GetClaimable returns the claimable balance for a specific address.
func GetClaimable(splitID string, addr std.Address) uint64 {
	s := mustGetSplit(splitID)
	return s.Balances[addr]
}

// ---------- render ----------

func Render(path string) string {
	if len(splits) == 0 {
		return "# Fee Split\n\nNo active splits.\n"
	}

	var b strings.Builder
	b.WriteString("# Fee Split\n\n")

	for id := range splits {
		b.WriteString(ufmt.Sprintf("## %s\n\n", id))
		b.WriteString("```\n")
		b.WriteString(GetSplitInfo(id))
		b.WriteString("```\n\n")
	}
	return b.String()
}

// ---------- helpers ----------

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
