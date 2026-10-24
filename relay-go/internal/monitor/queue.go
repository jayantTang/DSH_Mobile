package monitor

// 告警队列的存取：投递侧（admin 的 alert-dispatch）从这里取走、失败放回、
// 成功丢弃；收集侧只追加（见 monitor.go 的 appendLocked）。

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// ReadQueue 读一份队列文件，返回合法记录与坏行数。
//
// 坏行跳过而不是让整批失败：一条写坏的记录不该把其余告警一起卡住。
func ReadQueue(path string) ([]Record, int, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	defer file.Close()
	return readRecords(file)
}

func readRecords(reader io.Reader) ([]Record, int, error) {
	records := make([]Record, 0, 16)
	bad := 0
	buffered := bufio.NewReader(reader)
	for {
		line, err := buffered.ReadString('\n')
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			var record Record
			if decodeErr := json.Unmarshal([]byte(trimmed), &record); decodeErr != nil {
				bad++
			} else {
				records = append(records, record)
			}
		}
		if err != nil {
			if err == io.EOF {
				return records, bad, nil
			}
			return records, bad, err
		}
	}
}

// TakeQueue 是投递侧的原子取走：把 alerts.jsonl 重命名成 alerts.taken.jsonl，
// 再读它。队列不存在时返回空（不是错误）。
//
// 取走之后再拼正文、再投递：投递成功由调用方 DiscardTaken，失败由 RestoreQueue
// 原样追加回队列。任何一步都不会丢告警。
func TakeQueue(alertDir string) ([]Record, int, error) {
	queuePath := filepath.Join(alertDir, QueueName)
	takenPath := filepath.Join(alertDir, TakenName)
	if err := os.Rename(queuePath, takenPath); err != nil {
		if os.IsNotExist(err) {
			return nil, 0, nil
		}
		return nil, 0, fmt.Errorf("取走告警队列: %w", err)
	}
	records, bad, err := ReadQueue(takenPath)
	if err != nil {
		// 读不出来也要把文件放回去，下一次还能重试。
		restoreErr := RestoreQueue(alertDir)
		if restoreErr != nil {
			return nil, bad, fmt.Errorf("读告警队列: %w（放回也失败: %v）", err, restoreErr)
		}
		return nil, bad, fmt.Errorf("读告警队列: %w", err)
	}
	if len(records) == 0 {
		_ = DiscardTaken(alertDir)
	}
	return records, bad, nil
}

// RestoreQueue 把取走的文件原样追加回队列，然后删掉 taken。
//
// 追加失败时**保留** taken：宁可留一个待人工处理的文件，也不丢记录。
func RestoreQueue(alertDir string) error {
	queuePath := filepath.Join(alertDir, QueueName)
	takenPath := filepath.Join(alertDir, TakenName)
	payload, err := os.ReadFile(takenPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("读回待放回的告警: %w", err)
	}
	target, err := os.OpenFile(queuePath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("打开告警队列: %w", err)
	}
	if _, err := target.Write(payload); err != nil {
		_ = target.Close()
		return fmt.Errorf("放回告警: %w", err)
	}
	if err := target.Close(); err != nil {
		return fmt.Errorf("放回告警: %w", err)
	}
	return DiscardTaken(alertDir)
}

// DiscardTaken 删掉取走文件（投递成功之后）。
func DiscardTaken(alertDir string) error {
	err := os.Remove(filepath.Join(alertDir, TakenName))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
