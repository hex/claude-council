// ABOUTME: A council panel's connection to Claude Desktop (MCP Apps over postMessage)
// ABOUTME: Requests, tool calls, notifications, theme and the size the frame should take
// The page talks to Claude Desktop over postMessage (MCP Apps); it has no
// network access, so every read and save is a tool call the host relays.
class HostTimeout extends Error {}

const host = {
  nextId: 1,
  pending: new Map(),
  post(message) { window.parent.postMessage(message, '*') },
  // With `waitMs`, a request the host has not answered by then fails with a
  // HostTimeout, and a late answer to it is ignored: the host may never
  // answer a request it cancelled.
  request(method, params, waitMs) {
    return new Promise((resolve, reject) => {
      const id = host.nextId++
      const timer = waitMs === undefined ? undefined : setTimeout(() => {
        host.pending.delete(id)
        reject(new HostTimeout(`${method} had no answer within ${waitMs} ms`))
      }, waitMs)
      host.pending.set(id, {
        resolve: value => { clearTimeout(timer); resolve(value) },
        reject: err => { clearTimeout(timer); reject(err) },
      })
      host.post({ jsonrpc: '2.0', id, method, params })
    })
  },
  async tool(name, args) {
    const result = await host.request('tools/call', { name, arguments: args ?? {} })
    const text = result?.content?.[0]?.text ?? ''
    if (result?.isError) throw new Error(text || 'the tool failed')
    return JSON.parse(text)
  },
  // Opens the connection. `notifications` maps a notification's method, such
  // as ui/notifications/tool-result, to the function that takes its params;
  // they are registered first because the host may send them at once.
  async connect(appName, notifications) {
    window.addEventListener('message', event => {
      if (event.source !== window.parent) return
      const message = event.data
      if (!message || message.jsonrpc !== '2.0') return
      const waiting = message.id !== undefined && message.method === undefined ? host.pending.get(message.id) : undefined
      if (waiting) {
        host.pending.delete(message.id)
        if (message.error) waiting.reject(new Error(message.error.message ?? 'refused'))
        else waiting.resolve(message.result)
      } else if (message.method === 'ui/notifications/host-context-changed') {
        host.theme(message.params)
      } else if (message.id === undefined && notifications?.[message.method]) {
        notifications[message.method](message.params)
      } else if (message.method !== undefined && message.id !== undefined) {
        host.post({ jsonrpc: '2.0', id: message.id, result: {} })
      }
    })
    const hello = await host.request('ui/initialize', { appInfo: { name: appName, version: '1' }, appCapabilities: {}, protocolVersion: '2026-01-26' })
    host.theme(hello?.hostContext)
    host.post({ jsonrpc: '2.0', method: 'ui/notifications/initialized', params: {} })
    new ResizeObserver(host.reportSize).observe(document.body)
    host.reportSize()
  },
  // The body's own height, not the document's: the document is at least as
  // tall as the frame, so reporting it could never let the frame shrink. The
  // pages also call this after drawing, because a ResizeObserver runs only
  // when the frame renders, which a host may hold back for a frame out of view.
  reportSize() {
    host.post({ jsonrpc: '2.0', method: 'ui/notifications/size-changed', params: { height: Math.ceil(document.body.getBoundingClientRect().height) } })
  },
  theme(context) {
    if (context?.theme === 'light' || context?.theme === 'dark') document.documentElement.dataset.theme = context.theme
  },
}
