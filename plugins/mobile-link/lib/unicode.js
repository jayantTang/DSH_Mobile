/**
 * UTF-16 安全边界：落单代理项修复与按码元安全截断。
 *
 * 为什么需要（2026-10-17 事故的同一个根）：
 *
 *   JS 字符串按 UTF-16 码元索引。凡是 `text.slice(0, n)` 这类截断，n 落在代理对
 *   中间时就会留下**落单的高代理项**（`\ud83d`），序列化成 JSON 后是 `"\ud83d…"`。
 *   这种帧不是合法 Unicode：中转要按 UTF-8 计费，编码直接抛错（Python 版当年就是
 *   这么把连接打死的）；iOS 的 `JSONDecoder` 会整条拒绝（`Missing low code point
 *   in surrogate pair`）。中转现在会用 U+FFFD 修好再转发，但**生产端不该发出这种
 *   帧**——它是本连接器的出口，帧有效性归这里。
 *
 * 两件事分开：
 *   1. `repairLoneSurrogates`：出口兜底。帧里已经有落单代理项时替换成 U+FFFD，
 *      与中转的修复口径一致；
 *   2. `truncateSafe` / `sliceRangeSafe`：自己截断时就不制造落单代理项（预览、
 *      搜索片段、diff 正文）。兜底只防别人的数据，自己造出来的必须从源头修。
 */

/** JSON 转义里的四位十六进制（大小写都认）。 */
const HEX_UNIT = /^[0-9a-fA-F]{4}$/

function hexUnitAt(text, at) {
  if (at + 4 > text.length) return -1
  const raw = text.slice(at, at + 4)
  return HEX_UNIT.test(raw) ? Number.parseInt(raw, 16) : -1
}

/** 这个反斜杠本身是不是被转义了（前面有奇数个连续反斜杠）。 */
function isEscapedBackslash(text, index) {
  let count = 0
  for (let i = index - 1; i >= 0 && text[i] === '\\'; i -= 1) count += 1
  return count % 2 === 1
}

function isHighUnit(unit) {
  return unit >= 0xd800 && unit <= 0xdbff
}

function isLowUnit(unit) {
  return unit >= 0xdc00 && unit <= 0xdfff
}

/**
 * 扫描一段 JSON 文本，把**落单**的 `\uD800`–`\uDFFF` 转义换成 `\ufffd`。
 *
 * 只认真正的转义（`\\ud83d` 是字面量）；合法配对原样保留。替换串与转义同为
 * 6 个字符，帧长度不变。返回值带修复条数，调用方据此决定要不要记一条告警。
 *
 * @param {string} text JSON 文本
 * @returns {{ text: string, repaired: number }}
 */
export function repairLoneSurrogatesWithCount(text) {
  if (typeof text !== 'string') return { text, repaired: 0 }
  // 廉价前置判断：正常帧连 `\ud`/`\uD` 都没有，不做完整扫描。
  if (text.indexOf('\\ud') < 0 && text.indexOf('\\uD') < 0) return { text, repaired: 0 }

  let out = ''
  let last = 0
  let repaired = 0
  for (let i = 0; i + 5 < text.length; i += 1) {
    if (text[i] !== '\\' || text[i + 1] !== 'u') continue
    if (isEscapedBackslash(text, i)) continue
    const unit = hexUnitAt(text, i + 2)
    if (unit < 0) continue
    if (isHighUnit(unit)) {
      let paired = false
      if (text[i + 6] === '\\' && text[i + 7] === 'u') {
        const next = hexUnitAt(text, i + 8)
        paired = isLowUnit(next)
      }
      if (paired) {
        i += 11 // 整个 `\uXXXX\uXXXX` 是合法配对：跳过 12 个字符
        continue
      }
    } else if (!isLowUnit(unit)) {
      continue
    }
    out += `${text.slice(last, i)}\\ufffd`
    last = i + 6
    repaired += 1
  }
  if (repaired === 0) return { text, repaired: 0 }
  return { text: out + text.slice(last), repaired }
}

/** `repairLoneSurrogatesWithCount` 只取文本的那一半。 */
export function repairLoneSurrogates(text) {
  return repairLoneSurrogatesWithCount(text).text
}

/**
 * 截到 `end` 个**码元**为止，且不把代理对切开。
 *
 * 与 `text.slice(0, end)` 的差别只有一种：第 `end` 个码元是高代理项时把它让给
 * 后半截（结果最多少 1 个码元），从而不会留下落单的高代理项。
 */
export function truncateSafe(text, end) {
  if (typeof text !== 'string' || !(end > 0)) return ''
  if (text.length <= end) return text
  const unit = text.charCodeAt(end - 1)
  return text.slice(0, isHighUnit(unit) ? end - 1 : end)
}

/**
 * `text.slice(start, end)` 的安全版本：起点若落在低代理项上就后移一位，终点若
 * 落在高代理项上就前移一位；两端都不会制造落单代理项。
 */
export function sliceRangeSafe(text, start, end) {
  if (typeof text !== 'string') return ''
  let from = Math.max(0, Math.min(Number(start) || 0, text.length))
  let to = Math.max(from, Math.min(Number(end) || 0, text.length))
  if (isLowUnit(text.charCodeAt(from))) from += 1
  if (isHighUnit(text.charCodeAt(to - 1))) to -= 1
  return text.slice(from, Math.max(from, to))
}
