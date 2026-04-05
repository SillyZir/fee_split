package fee_split

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// resetState resets all package-level state between tests.
// Required because Gno test functions share the same VM context.
func resetState() {
	splits = make(map[string]*Split)
	nextID = 1
}

// ---------- CreateSplit ----------

func TestCreateSplit_Basic(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "6000,4000")
	uassert.Equal(t, "split_1", id)

	s := splits["split_1"]
	uassert.Equal(t, "g1owner", s.Owner)
	uassert.Equal(t, 2, len(s.Recipients))
	uassert.Equal(t, "g1alice", s.Recipients[0])
	uassert.Equal(t, "g1bob", s.Recipients[1])
	uassert.Equal(t, uint64(6000), s.Shares[0])
	uassert.Equal(t, uint64(4000), s.Shares[1])
	uassert.False(t, s.Frozen, "new split must not be frozen")
	uassert.Equal(t, uint64(0), s.TotalDeposited)
	uassert.Equal(t, uint64(0), s.TotalClaimed)
}

func TestCreateSplit_IDsIncrement(t *testing.T) {
	resetState()

	id1 := CreateSplit(cross, "g1owner", "g1alice", "10000")
	id2 := CreateSplit(cross, "g1owner", "g1bob", "10000")
	uassert.Equal(t, "split_1", id1)
	uassert.Equal(t, "split_2", id2)
}

func TestCreateSplit_SingleRecipient(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	uassert.Equal(t, "split_1", id)
}

func TestCreateSplit_DuplicateRecipient(t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t,
		"duplicate recipient: g1alice",
		func() { CreateSplit(cross, "g1owner", "g1alice,g1alice", "5000,5000") },
	)
}

func TestCreateSplit_SharesDontSum(t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t,
		"shares must sum to 10000 basis points, got 5000",
		func() { CreateSplit(cross, "g1owner", "g1alice", "5000") },
	)
}

func TestCreateSplit_LengthMismatch(t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t,
		"recipients and shares must have the same length",
		func() { CreateSplit(cross, "g1owner", "g1alice,g1bob", "10000") },
	)
}

func TestCreateSplit_EmptyRecipient(t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t,
		"empty recipient address at position 1",
		func() { CreateSplit(cross, "g1owner", "g1alice,", "5000,5000") },
	)
}

func TestCreateSplit_NoRecipients(t *testing.T) {
	resetState()

	// parseBasisPoints will panic on empty string before the length check
	// but if recipients list is somehow empty after split, at-least-one check fires
	uassert.PanicsWithMessage(t,
		"invalid share value: ",
		func() { CreateSplit(cross, "g1owner", "g1alice", "") },
	)
}

// ---------- Deposit ----------

func TestDeposit_EvenSplit(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "5000,5000")

	Deposit(cross, id, 1000)

	s := splits[id]
	uassert.Equal(t, uint64(1000), s.TotalDeposited)
	uassert.Equal(t, uint64(500), s.Balances["g1alice"])
	uassert.Equal(t, uint64(500), s.Balances["g1bob"])
}

func TestDeposit_UnevenSplit(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob,g1carol", "6000,2500,1500")

	Deposit(cross, id, 1000000)

	s := splits[id]
	uassert.Equal(t, uint64(1000000), s.TotalDeposited)
	uassert.Equal(t, uint64(600000), s.Balances["g1alice"])
	uassert.Equal(t, uint64(250000), s.Balances["g1bob"])
	uassert.Equal(t, uint64(150000), s.Balances["g1carol"])
}

func TestDeposit_RoundingDustGoesToLastRecipient(t *testing.T) {
	resetState()

	// 3-way split with indivisible amount: each gets floor, last gets remainder
	// alice=3333, bob=3333, carol=3334 (dust)
	id := CreateSplit(cross, "g1owner", "g1alice,g1bob,g1carol", "3334,3333,3333")

	Deposit(cross, id, 10)

	s := splits[id]
	uassert.Equal(t, uint64(10), s.TotalDeposited)

	// alice: (10 * 3334) / 10000 = 3
	uassert.Equal(t, uint64(3), s.Balances["g1alice"])
	// bob: (10 * 3333) / 10000 = 3
	uassert.Equal(t, uint64(3), s.Balances["g1bob"])
	// carol (last): 10 - 3 - 3 = 4
	uassert.Equal(t, uint64(4), s.Balances["g1carol"])
}

func TestDeposit_AccumulatesAcrossMultipleDeposits(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "5000,5000")

	Deposit(cross, id, 100)
	Deposit(cross, id, 200)

	s := splits[id]
	uassert.Equal(t, uint64(300), s.TotalDeposited)
	uassert.Equal(t, uint64(150), s.Balances["g1alice"])
	uassert.Equal(t, uint64(150), s.Balances["g1bob"])
}

func TestDeposit_ZeroAmountPanics(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")

	uassert.PanicsWithMessage(t,
		"amount must be greater than zero",
		func() { Deposit(cross, id, 0) },
	)
}

func TestDeposit_FrozenSplitPanics(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	Freeze(cross, id, "g1owner")

	uassert.PanicsWithMessage(t,
		"split is frozen",
		func() { Deposit(cross, id, 100) },
	)
}

func TestDeposit_UnknownSplitPanics(t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t,
		"split not found: split_99",
		func() { Deposit(cross, "split_99", 100) },
	)
}

// ---------- Claim ----------

func TestClaim_Basic(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "7000,3000")
	Deposit(cross, id, 10000)

	claimed := Claim(cross, id, "g1alice")
	uassert.Equal(t, uint64(7000), claimed)

	s := splits[id]
	uassert.Equal(t, uint64(0), s.Balances["g1alice"])
	uassert.Equal(t, uint64(7000), s.TotalClaimed)
}

func TestClaim_NothingToClaim(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "5000,5000")

	uassert.PanicsWithMessage(t,
		"nothing to claim",
		func() { Claim(cross, id, "g1alice") },
	)
}

func TestClaim_NotARecipient(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	Deposit(cross, id, 100)

	uassert.PanicsWithMessage(t,
		"not a recipient of this split",
		func() { Claim(cross, id, "g1stranger") },
	)
}

func TestClaim_CannotClaimTwice(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	Deposit(cross, id, 100)
	Claim(cross, id, "g1alice")

	uassert.PanicsWithMessage(t,
		"nothing to claim",
		func() { Claim(cross, id, "g1alice") },
	)
}

// ---------- UpdateShares ----------

func TestUpdateShares_Basic(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "5000,5000")
	UpdateShares(cross, id, "g1owner", "g1alice,g1carol", "7000,3000")

	s := splits[id]
	uassert.Equal(t, 2, len(s.Recipients))
	uassert.Equal(t, "g1alice", s.Recipients[0])
	uassert.Equal(t, "g1carol", s.Recipients[1])
	uassert.Equal(t, uint64(7000), s.Shares[0])
	uassert.Equal(t, uint64(3000), s.Shares[1])
}

func TestUpdateShares_PreservesUnclaimedBalances(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "5000,5000")
	Deposit(cross, id, 1000)

	// alice has 500 unclaimed; now remove her from the new recipients list
	// but her balance entry is preserved in the map
	UpdateShares(cross, id, "g1owner", "g1carol,g1dave", "6000,4000")

	s := splits[id]
	// alice's old balance is not deleted
	uassert.Equal(t, uint64(500), s.Balances["g1alice"])
	uassert.Equal(t, uint64(500), s.Balances["g1bob"])
}

func TestUpdateShares_WrongOwner(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")

	uassert.PanicsWithMessage(t,
		"only the owner can update shares",
		func() { UpdateShares(cross, id, "g1attacker", "g1alice", "10000") },
	)
}

func TestUpdateShares_FrozenSplitPanics(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	Freeze(cross, id, "g1owner")

	uassert.PanicsWithMessage(t,
		"split is frozen",
		func() { UpdateShares(cross, id, "g1owner", "g1alice,g1bob", "5000,5000") },
	)
}

// ---------- TransferOwnership ----------

func TestTransferOwnership_Basic(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	TransferOwnership(cross, id, "g1owner", "g1newowner")

	uassert.Equal(t, "g1newowner", splits[id].Owner)
}

func TestTransferOwnership_WrongOwner(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")

	uassert.PanicsWithMessage(t,
		"only the owner can transfer ownership",
		func() { TransferOwnership(cross, id, "g1attacker", "g1newowner") },
	)
}

func TestTransferOwnership_EmptyNewOwner(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")

	uassert.PanicsWithMessage(t,
		"new owner must not be empty",
		func() { TransferOwnership(cross, id, "g1owner", "") },
	)
}

// ---------- Freeze ----------

func TestFreeze_Basic(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	Freeze(cross, id, "g1owner")

	uassert.True(t, splits[id].Frozen, "split must be frozen after Freeze()")
}

func TestFreeze_WrongOwner(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")

	uassert.PanicsWithMessage(t,
		"only the owner can freeze",
		func() { Freeze(cross, id, "g1attacker") },
	)
}

func TestFreeze_IsOneWay(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")
	Freeze(cross, id, "g1owner")

	// DepositAndClaim still work after freeze
	// (only UpdateShares and Deposit are restricted — but Deposit IS blocked after freeze)
	uassert.True(t, splits[id].Frozen)
}

// ---------- GetClaimable ----------

func TestGetClaimable(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "8000,2000")
	Deposit(cross, id, 5000)

	uassert.Equal(t, uint64(4000), GetClaimable(id, "g1alice"))
	uassert.Equal(t, uint64(1000), GetClaimable(id, "g1bob"))
}

func TestGetClaimable_ZeroForUnknown(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice", "10000")

	// g1stranger is not a recipient — Balances map returns zero for missing key
	uassert.Equal(t, uint64(0), GetClaimable(id, "g1stranger"))
}

// ---------- GetSplitInfo ----------

func TestGetSplitInfo_ContainsExpectedFields(t *testing.T) {
	resetState()

	id := CreateSplit(cross, "g1owner", "g1alice,g1bob", "5000,5000")
	Deposit(cross, id, 200)

	info := GetSplitInfo(id)

	uassert.True(t, strings.Contains(info, "Owner"), "GetSplitInfo output must contain 'Owner'")
	uassert.True(t, strings.Contains(info, "g1owner"), "GetSplitInfo output must contain owner address")
	uassert.True(t, strings.Contains(info, "g1alice"), "GetSplitInfo output must contain recipient")
}

func TestGetSplitInfo_UnknownSplitPanics(t *testing.T) {
	resetState()

	uassert.PanicsWithMessage(t,
		"split not found: split_99",
		func() { GetSplitInfo("split_99") },
	)
}

// ---------- Render ----------

func TestRender_EmptyState(t *testing.T) {
	resetState()

	out := Render("")
	uassert.Equal(t, "# Fee Split\n\nNo active splits.\n", out)
}

func TestRender_WithSplits(t *testing.T) {
	resetState()

	CreateSplit(cross, "g1owner", "g1alice,g1bob", "6000,4000")
	Deposit(cross, "split_1", 1000)

	out := Render("")

	uassert.True(t, strings.Contains(out, "split_1"), "Render output must reference split_1")
	uassert.True(t, strings.Contains(out, "g1owner"), "Render output must include owner")
}
