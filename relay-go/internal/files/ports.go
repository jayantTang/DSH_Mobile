package files

import (
	"context"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Store 是文件端点需要的唯一仓储方法（DESIGN-20261023 §2.5：1 个方法）。
//
// 两条文件端点只认设备令牌：上传/下载的桥状态机在 hub，字节额度在 Link，
// 仓储层只负责"这个令牌是谁"。因此这里不需要 ListDevices 或推送方法。
type Store interface {
	DeviceByToken(ctx context.Context, token string) (store.Device, bool, error)
}
