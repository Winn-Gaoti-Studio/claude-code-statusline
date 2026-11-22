import { expect, test } from 'claude-code/testing'

const ROW = {
  id: 'a1',
  rowIds: ['a1'],
  columns: 100,
  name: 'reviewer',
  description: 'Review the auth diff',
  type: 'general-purpose',
  status: 'running',
  kind: 'local_agent',
  taskStatus: 'running',
  label: 'Review the auth diff',
  startTime: 0,
  cwd: '/repo',
  model: 'claude-opus-5-5',
  effort: 'high',
  contextWindowSize: 200000,
  tokenCount: 34000,
  tokenSamples: [34000],
  hasRow: true,
} as const

const plain = (text: string | undefined) => (text ?? '').replace(/\x1b\[[0-9;]*m/g, '')

test('an agent row gets the custom body on each surface', async ($, on) => {
  let bodies: (string | undefined)[] = []
  on('ui.render', { component: 'AgentRow' }, (_, e, next) => {
    bodies.push(e.props.body)
    return next(e)
  })
  for (const surface of ['terminal', 'vscode', 'desktop'] as const) {
    bodies = []
    const ui = await $.ui.mount({ plugin: 'subagent-rows', surface, component: 'AgentRow', props: ROW })
    await ui.unmount()
    expect(bodies.length > 0).toBe(true)
    expect(plain(bodies[0])).toBe('reviewer  Review the auth diff  opus high  34k 17%')
  }
})

test('the mod replaces a body that the old setting gave', async ($, on) => {
  const bodies: (string | undefined)[] = []
  on('ui.render', { component: 'AgentRow' }, (_, e, next) => {
    bodies.push(e.props.body)
    return next(e)
  })
  const ui = await $.ui.mount({
    plugin: 'subagent-rows',
    surface: 'terminal',
    component: 'AgentRow',
    props: { ...ROW, body: 'old body', columns: undefined },
  })
  await ui.unmount()
  expect(plain(bodies[0])).toBe('reviewer  Review the auth diff  opus high  34k 17%')
})
