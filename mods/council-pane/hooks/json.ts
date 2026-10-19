// ABOUTME: The one shape test for parsed JSON the modules share: a plain object, not null or an array
// ABOUTME: Every reader of a file, the store or a tool's input narrows through it before touching a field

export function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}
