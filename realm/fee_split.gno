package fee_split

import (
	"std"
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
	Archived       bool
}

const (
	MaxRecipients    = 20
	MaxSplitsPerOwner = 10
	MaxSplitsGlobal  = 500
)

var (
	splits      map[string]*Split
	splitIDs    []string // insertion-ordered for deterministic Render
	ownerSplits map[string]int
	nextID      int
)

func init() {
	splits = make(map[string]*Split)
	splitIDs = []string{}
	ownerSplits = make(map[string]int)
	nextID = 1
}

func caller() string {
	return string(std.PreviousRealm().Address())
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

func mustGetActive(id string) *Split {
	s := mustGetSplit(id)
	if s.Archived {
		panic("split is archived: " + id)
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

// CreateSplit registers a new split. The caller becomes the owner.
// Recipients and shares are comma-separated; shares are in basis points
// summing to 10000.
func CreateSplit(_ realm, recipientList, shareList string) string {
	if len(splits) >= MaxSplitsGlobal {
		panic("global split limit reached")
	}
	owner := caller()
	if ownerSplits[owner] >= MaxSplitsPerOwner {
		panic("per-owner split limit reached")
	}

	recipients := parseAddresses(recipientList)
	shares := parseBasisPoints(shareList)

	if len(recipients) != len(shares) {
		panic("recipients and shares must have the same length")
	}
	if len(recipients) == 0 {
		panic("at least one recipient is required")
	}
	if len(recipients) > MaxRecipients {
		panic("too many recipients (max " + strconv.Itoa(MaxRecipients) + ")")
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
	splitIDs = append(splitIDs, id)
	ownerSplits[owner]++
	return id
}

// Deposit distributes amount across recipients proportionally.
// Rounding dust goes to the highest-share recipient (deterministic,
// not order-dependent).
func Deposit(_ realm, splitID string, amount uint64) {
	s := mustGetActive(splitID)
	if s.Frozen {
		panic("split is frozen")
	}
	if amount == 0 {
		panic("amount must be greater than zero")
	}

	s.TotalDeposited += amount

	// Find the highest-share recipient for dust assignment
	dustIdx := 0
	for i := 1; i < len(s.Shares); i++ {
		if s.Shares[i] > s.Shares[dustIdx] {
			dustIdx = i
		}
	}

	var distributed uint64
	for i, r := range s.Recipients {
		share := (amount * s.Shares[i]) / 10000
		s.Balances[r] += share
		distributed += share
	}

	// Assign dust to highest-share recipient
	dust := amount - distributed
	if dust > 0 {
		s.Balances[s.Recipients[dustIdx]] += dust
	}
}

// Claim withdraws the caller's accumulated balance.
func Claim(_ realm, splitID string) uint64 {
	s := mustGetActive(splitID)
	addr := caller()

	bal, exists := s.Balances[addr]
	if !exists {
		panic("not a recipient of this split")
	}
	if bal == 0 {
		panic("nothing to claim")
	}

	s.Balances[addr] = 0
	s.TotalClaimed += bal
	return bal
}

// UpdateShares replaces recipients and shares. Owner only. Not if frozen.
func UpdateShares(_ realm, splitID, recipientList, shareList string) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
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
	if len(recipients) > MaxRecipients {
		panic("too many recipients (max " + strconv.Itoa(MaxRecipients) + ")")
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
func TransferOwnership(_ realm, splitID, newOwner string) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
		panic("only the owner can transfer ownership")
	}
	if newOwner == "" {
		panic("new owner must not be empty")
	}
	s.Owner = newOwner
}

// Freeze permanently locks shares. One-way, cannot be undone.
func Freeze(_ realm, splitID string) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
		panic("only the owner can freeze")
	}
	s.Frozen = true
}

// Archive marks a fully-claimed split as archived. Only the owner can
// archive, and only if all balances are zero. Archived splits are excluded
// from Render and block all further interaction. Cannot be undone.
func Archive(_ realm, splitID string) {
	s := mustGetActive(splitID)
	if caller() != s.Owner {
		panic("only the owner can archive")
	}

	for _, r := range s.Recipients {
		if s.Balances[r] > 0 {
			panic("cannot archive: outstanding balance for " + r)
		}
	}

	s.Archived = true

	// Free the owner's slot so they can create new splits
	ownerSplits[s.Owner]--
	if ownerSplits[s.Owner] <= 0 {
		delete(ownerSplits, s.Owner)
	}

	// Remove from active ID list (keeps map entry for audit)
	for i, id := range splitIDs {
		if id == splitID {
			splitIDs = append(splitIDs[:i], splitIDs[i+1:]...)
			break
		}
	}
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

	for _, id := range splitIDs {
		s := splits[id]
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
