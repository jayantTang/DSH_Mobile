/**
 * 已知为空的推导：一次窗口回包里，哪些号确认没有内容。
 *
 * 只在"从最老一条返回到窗口上界"之间下结论：窗口下界到最老返回之间可能被
 * 字节/条数截断，那一段没有被完整扫描，不能判空。上界取 `before - 1`。
 */
export function emptySpans(records, lower, upper) {
  const seqs = (records ?? [])
    .map((record) => record?.event?.seq)
    .filter((seq) => Number.isInteger(seq) && seq >= lower && seq <= upper)
    .sort((a, b) => a - b)
  if (seqs.length === 0) return []
  const spans = []
  let cursor = seqs[0]
  for (const seq of seqs) {
    if (seq > cursor) spans.push([cursor, seq - 1])
    cursor = seq + 1
  }
  if (upper >= cursor) spans.push([cursor, upper])
  return spans
}
