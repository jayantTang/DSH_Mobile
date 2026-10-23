package dlp

import (
	"sync"
	"sync/atomic"
)

// BufferPool 复用帧字节缓冲。
//
// 每条 WS 消息原本由 `conn.Read` 里的 `io.ReadAll` 新建一块 512 B 起的切片
// （pprof：一次 300 档压测里 io.ReadAll 累计 29 MiB、占分配总量 9.4%）。帧的
// 生命周期很规整——读循环取、写循环还——所以一个 sync.Pool 就够。
//
// 大帧不回池：一张 32 MiB 的图片帧如果留在池里，池会变成常驻内存；超过
// maxPooledCapacity 的缓冲直接交给 GC。
type BufferPool struct {
	pool        sync.Pool
	outstanding atomic.Int64
}

// maxPooledCapacity 是允许回池的最大容量：32 KiB 盖住绝大多数控制帧与流式小帧，
// 又不会让池变成大帧的仓库。
const maxPooledCapacity = 32 << 10

// initialBufferCapacity 是新缓冲的初始容量：一拍心跳、一条 req、一条 res 都在
// 128 B 以内，512 B 让第一次读不用扩容。
const initialBufferCapacity = 512

// headroomCapacity 是"就地追加成员"需要的余量（`,"deviceId":"dev_xxx"`）。
const headroomCapacity = 64

// NewBufferPool 建一个空池。
func NewBufferPool() *BufferPool { return &BufferPool{} }

// Get 借一块缓冲（长度为 0，容量足够放下一条小帧）。
func (p *BufferPool) Get() *Buffer {
	buffer, ok := p.pool.Get().(*Buffer)
	if !ok {
		buffer = &Buffer{bytes: make([]byte, 0, initialBufferCapacity)}
	}
	// pool 指针在 Release 里被清空（防重复归还），取出时重新挂上。
	buffer.pool = p
	p.outstanding.Add(1)
	return buffer
}

// Outstanding 是还没归还的缓冲数量（诊断/用例断言用）。
func (p *BufferPool) Outstanding() int64 { return p.outstanding.Load() }

// Buffer 是一帧字节的缓冲，一次 Get 对应一次 Release。
//
// Release 之后 Buffer 的内容不再可用：它可能已经被下一条帧复用。
type Buffer struct {
	bytes []byte
	pool  *BufferPool
}

// Bytes 是当前内容。
func (b *Buffer) Bytes() []byte { return b.bytes }

// SetBytes 用新切片替换内容（容量变化时也要更新，回池时按新容量判断）。
func (b *Buffer) SetBytes(data []byte) { b.bytes = data }

// Reserve 保证剩余容量至少有 extra 字节，供就地追加成员使用。
//
// 扩容是摊还的：容量按翻倍增长，之后的帧不会每次都付出复制代价。
func (b *Buffer) Reserve(extra int) {
	if cap(b.bytes)-len(b.bytes) >= extra {
		return
	}
	grown := make([]byte, len(b.bytes), growCapacity(len(b.bytes)+extra))
	copy(grown, b.bytes)
	b.bytes = grown
}

// Release 把缓冲还回池；重复调用与 nil 都是安全的。
func (b *Buffer) Release() {
	if b == nil || b.pool == nil {
		return
	}
	pool := b.pool
	b.pool = nil
	pool.outstanding.Add(-1)
	if cap(b.bytes) > maxPooledCapacity {
		return // 大帧不回池：否则池会常驻几十 MiB
	}
	b.bytes = b.bytes[:0]
	pool.pool.Put(b)
}

// Headroom 供读循环调用：为"就地追加 deviceId"预留余量。
func (b *Buffer) Headroom() { b.Reserve(headroomCapacity) }
