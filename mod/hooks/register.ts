import type { Register } from 'claude-code'

// Subagent panel rows. This mod replaces the `subagentStatusLine` command
// (`subagent-statusline.sh`), which Claude Code deprecated in favor of mods.
// renderBody gives the same text as that script, byte for byte:
// tests/subagent-mod.parity.sh compares the two on the same fixtures.
// The palette and the token format are the same as in statusline.sh.

const blue = '\x1b[38;2;0;153;255m'
const green = '\x1b[38;2;0;175;80m'
const red = '\x1b[38;2;255;85;85m'
const yellow = '\x1b[38;2;230;200;0m'
const orange = '\x1b[38;2;255;176;85m'
const dim = '\x1b[2m'
const reset = '\x1b[0m'

// The fields of an agent row that the body uses. AgentInfo in the mod API
// has these fields and more.
export type RowInput = {
  name?: string
  description?: string
  label?: string
  tokenCount?: number
  contextWindowSize?: number
  model?: string
  effort?: string | number
}

// Round the decimal digits of a non-negative number to `places` fraction
// digits, half to even on the exact value. This is the result of C printf,
// which statusline.sh gets through awk.
function printfFixed(value: number, places: number): string {
  const exact = value.toPrecision(100)
  const [whole, fraction = ''] = exact.split('.')
  const kept = fraction.slice(0, places).padEnd(places, '0')
  const rest = fraction.slice(places)
  // A token count has far fewer than 15 digits, so a Number holds it exactly.
  let digits = Number(whole + kept)
  const first = rest.charAt(0)
  const tail = rest.slice(1)
  if (first > '5' || (first === '5' && /[1-9]/.test(tail))) {
    digits += 1
  } else if (first === '5' && digits % 2 === 1) {
    digits += 1
  }
  const text = digits.toString().padStart(places + 1, '0')
  return places === 0 ? text : `${text.slice(0, -places)}.${text.slice(-places)}`
}

export function formatTokens(num: number): string {
  if (num >= 1000000) return `${printfFixed(num / 1000000, 1)}m`
  if (num >= 1000) {
    let q = Math.floor(num / 1000)
    const r = num % 1000
    if (r > 500 || (r === 500 && q % 2 === 1)) q += 1
    return `${q}k`
  }
  return String(num)
}

// Terminal cells of one code point. These ranges are the same as the
// byte ranges of cell_width in the shell scripts.
function charWidth(cp: number): number {
  if (cp >= 0x10000) return 2
  if (cp >= 0x2e80 && cp <= 0xdfff) return 2
  if (cp >= 0xfe30 && cp <= 0xfe4f) return 2
  if (cp >= 0xff00 && cp <= 0xff60) return 2
  if (cp >= 0xffe0 && cp <= 0xffe6) return 2
  return 1
}

export function cellWidth(s: string): number {
  let width = 0
  for (const ch of s) width += charWidth(ch.codePointAt(0) ?? 0)
  return width
}

// Cap s at maxlen cells. The text ends in "…" and the cut is between whole
// characters.
export function truncateEnd(s: string, maxlen: number): string {
  const cap = maxlen < 1 ? 1 : maxlen
  if (cellWidth(s) <= cap) return s
  let out = ''
  let width = 0
  for (const ch of s) {
    const w = charWidth(ch.codePointAt(0) ?? 0)
    if (width + w > cap - 1) break
    out += ch
    width += w
  }
  return `${out}…`
}

function colorForPct(pct: number): string {
  if (pct >= 90) return red
  if (pct >= 70) return yellow
  if (pct >= 50) return orange
  return green
}

// A resolved ID such as claude-opus-5-5[1m], or a provider ID such as
// us.anthropic.claude-sonnet-5-v1:0, becomes the family word. Other text
// stays as it is, capped at 12 cells.
export function modelFamily(model: string): string {
  let family = model
  const at = model.lastIndexOf('claude-')
  if (at >= 0) {
    family = model.slice(at + 'claude-'.length)
    const end = family.search(/[-[:@]/)
    if (end >= 0) family = family.slice(0, end)
  }
  return truncateEnd(family, 12)
}

// The effort label in the color of its level. A numeric token budget shows
// as a short count. The badge has no symbol, because terminals show symbols
// at different widths.
function effortBadge(effort: string): { text: string; width: number } {
  if (effort === '') return { text: '', width: 0 }
  let color = dim
  let label = effort
  if (effort === 'max') color = red
  else if (effort === 'xhigh') color = orange
  else if (effort === 'high') color = yellow
  else if (effort === 'medium') color = green
  else if (/^[0-9]+$/.test(effort)) label = formatTokens(Number(effort))
  return { text: `${color}${label}${reset}`, width: cellWidth(label) }
}

function oneLine(value: unknown): string {
  return value == null ? '' : String(value).replace(/[\t\n\r\x1f]/g, ' ')
}

function metaWidth(family: string, badgeWidth: number): number {
  let width = family === '' ? 0 : 2 + cellWidth(family)
  if (badgeWidth > 0) width = width > 0 ? width + 1 + badgeWidth : 2 + badgeWidth
  return width
}

export function renderBody(row: RowInput, columns = 80): string {
  const cols = Number.isInteger(columns) ? columns : 80
  let name = oneLine(row.name)
  const desc = oneLine(row.description ?? row.label)
  const tok = Number.isInteger(row.tokenCount) ? (row.tokenCount as number) : 0
  const ctx = Number.isInteger(row.contextWindowSize) ? (row.contextWindowSize as number) : 0
  const model = oneLine(row.model)

  let family = model === '' ? '' : modelFamily(model)
  let badge = effortBadge(oneLine(row.effort))

  let tokseg = `${dim}${formatTokens(tok)}${reset}`
  if (ctx > 0) {
    const pct = Math.min(Math.floor((tok * 100) / ctx), 100)
    tokseg = `${dim}${formatTokens(tok)}${reset} ${colorForPct(pct)}${pct}%${reset}`
  }

  // Keep the name short. The description gets the cells that remain. When
  // the model and effort make the description less than 8 cells, the badge
  // goes first, then the family.
  name = truncateEnd(name, 22)
  let descCap = cols - cellWidth(name) - 24
  let meta = metaWidth(family, badge.width)
  if (descCap - meta < 8 && badge.width > 0) {
    badge = { text: '', width: 0 }
    meta = metaWidth(family, 0)
  }
  if (descCap - meta < 8 && family !== '') {
    family = ''
    meta = metaWidth('', badge.width)
  }
  descCap -= meta
  let metaText = family === '' ? '' : `${dim}${family}${reset}`
  if (badge.text !== '') metaText += (metaText === '' ? '' : ' ') + badge.text
  descCap = Math.min(Math.max(descCap, 8), 64)

  let label = name === '' ? '' : `${blue}${name}${reset}`
  if (desc !== '') {
    const descText = `${dim}${truncateEnd(desc, descCap)}${reset}`
    label = label === '' ? descText : `${label}  ${descText}`
  }
  let content = label
  if (metaText !== '') content += `  ${metaText}`
  return `${content}  ${tokseg}`
}

export const register: Register = on => {
  on('ui.render', { component: 'AgentRow' }, ($, e, next) => {
    let body: string
    try {
      body = renderBody(e.props, e.props.columns)
    } catch {
      return next(e)
    }
    return next({ ...e, props: { ...e.props, body } })
  })
}
