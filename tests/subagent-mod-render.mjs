// Read a subagentStatusLine payload ({columns, tasks}) on stdin. Write one
// {"id","content"} line for each task, with the body from the mod. The output
// has the same form as subagent-statusline.sh, so the parity test can compare
// the two outputs byte for byte.
import { readFileSync } from 'node:fs'
import { renderBody } from '../mod/hooks/register.ts'

const input = JSON.parse(readFileSync(0, 'utf8'))
const lines = []
for (const task of input.tasks ?? []) {
  if (!task.id) continue
  lines.push(JSON.stringify({ id: task.id, content: renderBody(task, input.columns ?? 80) }))
}
process.stdout.write(lines.length ? `${lines.join('\n')}\n` : '')
