package opsreport

import (
	"context"
	"sort"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// fakeSource 是一份固定的取数输入（不用库文件，golden 与时间无关）。
type fakeSource struct {
	devices     []store.Device
	agents      []store.Agent
	accounts    []store.Account
	invites     []store.Invite
	enrollments []store.Enrollment
	usage       map[int64][]store.UsageRow
	totals      []store.UsageTotal
	unread      map[string]int
	threads     []store.FeedbackThread
	digest      map[string]store.FeedbackDigestEntry
}

func (f *fakeSource) ListDevices(_ context.Context, agentID string,
	includeRevoked bool) ([]store.Device, error) {
	out := make([]store.Device, 0, len(f.devices))
	for _, device := range f.devices {
		if agentID != "" && device.AgentID != agentID {
			continue
		}
		if !includeRevoked && device.RevokedAt != nil {
			continue
		}
		out = append(out, device)
	}
	return out, nil
}

func (f *fakeSource) ListAgents(_ context.Context, accountID string) ([]store.Agent, error) {
	out := make([]store.Agent, 0, len(f.agents))
	for _, agent := range f.agents {
		if accountID != "" && agent.AccountID != accountID {
			continue
		}
		out = append(out, agent)
	}
	return out, nil
}

func (f *fakeSource) ListAccounts(context.Context) ([]store.Account, error) {
	return append([]store.Account(nil), f.accounts...), nil
}

func (f *fakeSource) ListInvites(_ context.Context, includeUsed bool) ([]store.Invite, error) {
	out := make([]store.Invite, 0, len(f.invites))
	for _, invite := range f.invites {
		if !includeUsed && invite.UsedAt != nil {
			continue
		}
		out = append(out, invite)
	}
	return out, nil
}

func (f *fakeSource) ListEnrollments(context.Context) ([]store.Enrollment, error) {
	return append([]store.Enrollment(nil), f.enrollments...), nil
}

func (f *fakeSource) UsageRows(_ context.Context, day int64) ([]store.UsageRow, error) {
	return append([]store.UsageRow(nil), f.usage[day]...), nil
}

func (f *fakeSource) UsageTotals(_ context.Context, _ int, _ string) ([]store.UsageTotal, error) {
	return append([]store.UsageTotal(nil), f.totals...), nil
}

func (f *fakeSource) OwnerUnreadCounts(context.Context) (map[string]int, error) {
	out := make(map[string]int, len(f.unread))
	for key, value := range f.unread {
		out[key] = value
	}
	return out, nil
}

func (f *fakeSource) ListFeedbackThreads(_ context.Context, status *string,
	sinceMS *int64, limit int, _ int) ([]store.FeedbackThread, error) {
	out := make([]store.FeedbackThread, 0, len(f.threads))
	for _, thread := range f.threads {
		if status != nil && *status != "" && thread.Status != *status {
			continue
		}
		if sinceMS != nil && thread.CreatedAt < *sinceMS {
			continue
		}
		out = append(out, thread)
	}
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *fakeSource) FeedbackDigest(_ context.Context, threadIDs []string,
	_ int) (map[string]store.FeedbackDigestEntry, error) {
	wanted := make(map[string]struct{}, len(threadIDs))
	for _, id := range threadIDs {
		wanted[id] = struct{}{}
	}
	out := map[string]store.FeedbackDigestEntry{}
	for id, entry := range f.digest {
		if _, ok := wanted[id]; ok {
			out[id] = entry
		}
	}
	return out, nil
}

// 让 fakeSource 的桩显式满足端口（编译器会检查签名）。
var _ Source = (*fakeSource)(nil)

// usageTotalRows 按第一次出现的设备顺序构造 UsageTotals 行，便于固定 golden。
func usageTotalRows(rows map[int64][]store.UsageRow) []store.UsageTotal {
	type key struct {
		device  string
		account string
	}
	first := map[key]int64{}
	for day, entries := range rows {
		for _, entry := range entries {
			entryKey := key{device: entry.DeviceID, account: entry.AccountID}
			if current, ok := first[entryKey]; !ok || day < current {
				first[entryKey] = day
			}
		}
	}
	keys := make([]key, 0, len(first))
	for item := range first {
		keys = append(keys, item)
	}
	sort.Slice(keys, func(left, right int) bool {
		if keys[left].device != keys[right].device {
			return keys[left].device < keys[right].device
		}
		return keys[left].account < keys[right].account
	})
	out := make([]store.UsageTotal, 0, len(keys))
	for _, item := range keys {
		device := item.device
		out = append(out, store.UsageTotal{Day: first[item], DeviceID: &device})
	}
	return out
}
