// ABOUTME: The council pane's $.state contract: the heads-up side-check's per-session state
// ABOUTME: Self-contained, as claude plugin validate requires; heads-up.ts and pane.tsx import these types

/** Per-session state in $.state; survives hot reload, never crosses sessions. */
export type Session = {
  /** The running turn and the conversation's message count at its first step: the message index within the turn is the difference. */
  readonly turnBase: { turnId: string; messageCount: number } | null
  /** The turn a note was offered in; at most one note per turn. */
  readonly offeredTurn: string | null
  readonly phase: Phase
  /** Tell-Claude text armed for the person's next prompt; cleared when it goes. */
  readonly pendingContext: string | null
}

/** A check in flight and a note on screen cannot both be true: the union says so. */
export type Phase =
  | { kind: 'idle' }
  | { kind: 'checking'; turnId: string; checkId: string; runDir: string; startedMs: number }
  | { kind: 'showing'; note: Note; expanded: boolean }

/** One check's answer, validated from result.json. */
export type Note = {
  /** The check id; dedupes answer application. */
  readonly id: string
  /** At most TOPIC_CHARS (heads-up.ts); what seen and known hold. */
  readonly topic: string
  /** The one sentence after "Heads up ·". */
  readonly headline: string
  /** Shown on learn more and sent with the next prompt. */
  readonly detail: string
  readonly seat: string
  readonly payloadBytes: number
  readonly elapsedMs: number
}

declare module 'claude-code' {
  interface PluginState {
    'claude-council': { headsUp: Session }
  }
}
