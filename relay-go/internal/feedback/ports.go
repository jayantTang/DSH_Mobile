package feedback

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Store 是反馈四端点需要的仓储面（DESIGN-20261023 §2.5：9 个方法）。
//
// 它**不含 owner 侧方法**（CreateNotice、SetFeedbackSubject、OwnerUnreadCounts、
// 列表与摘要等）：那些只由 admin 命令使用，用户侧端点拿不到，也就不会误用。
//
// 领域归属：全部是 FeedbackStore 的子集，外加 DeviceByToken 用来认人。
type Store interface {
	DeviceByToken(ctx context.Context, token string) (store.Device, bool, error)
	CreateFeedbackThread(ctx context.Context, in store.CreateFeedbackThreadInput) (store.CreatedFeedbackThread, error)
	AppendFeedbackMessage(ctx context.Context, in store.AppendFeedbackInput) (*store.AppendedFeedbackMessage, error)
	FeedbackThread(ctx context.Context, threadID string, ticketHash *string, messagesPerThread int) (*store.FeedbackThread, error)
	FeedbackThreadsByTickets(ctx context.Context, pairs []store.TicketPair, messagesPerThread int) ([]store.FeedbackThread, error)
	FeedbackThreadsByDevice(ctx context.Context, deviceID string, accountID *string, messagesPerThread int) ([]store.FeedbackThread, error)
	NoticesForAccount(ctx context.Context, accountID string, limit int) ([]store.Notice, error)
	MarkThreadRead(ctx context.Context, threadID string, uptoMS *int64) (bool, error)
	MarkNoticesRead(ctx context.Context, accountID string, notices []string, at int64) (int64, error)
}
