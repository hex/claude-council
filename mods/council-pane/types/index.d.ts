// ABOUTME: The council pane's $.state contract: the heads-up side-check's per-session state
// ABOUTME: Self-contained, as claude plugin validate requires; heads-up.ts and pane.tsx import these types

/** Per-session state in $.state; survives hot reload, never crosses sessions. */
export type Session = {
  /** The turn a note was offered in; at most one note per turn. */
  readonly offeredTurn: string | null
  readonly phase: Phase
  /** The seat ran out of credits: no check launches until /heads-up on or a fresh session. */
  readonly paused: Paused | null
  /** How many times /heads-up on resumed this session; a check stamps it at launch. */
  readonly resumes: number
}

/**
 * The session as $.state may hold it: one written without `paused` or
 * `resumes`, session or check, lacks them. storedSession (heads-up.ts) reads
 * it as a Session.
 */
export type StoredSession = Omit<Session, 'paused' | 'resumes' | 'phase'> & {
  readonly paused?: Paused | null
  readonly resumes?: number
  readonly phase: Exclude<Phase, { kind: 'checking' }> | (Omit<Extract<Phase, { kind: 'checking' }>, 'resumes'> & { readonly resumes?: number })
}

export type Paused = {
  readonly seat: string
  /** The seat's own words for why. */
  readonly detail: string
  /** The person dismissed the red row; the pause holds. */
  readonly acknowledged: boolean
}

/** A check in flight and a note on screen cannot both be true: the union says so. */
export type Phase =
  | { kind: 'idle' }
  /** `resumes` is the session's count at launch: a quota answer pauses only when no /heads-up on came since. */
  | { kind: 'checking'; turnId: string; checkId: string; runDir: string; startedMs: number; resumes: number }
  | { kind: 'showing'; note: Note; expanded: boolean }

/** The builtin's two tags: a concept that matters, or this session's own work. */
export type Tag = 'You should know' | 'Heads up'

/** One check's answer, validated from result.json. */
export type Note = {
  /** The check id; dedupes answer application. */
  readonly id: string
  readonly tag: Tag
  /** At most TOPIC_CHARS (heads-up.ts); what seen and known hold. */
  readonly topic: string
  /** The one sentence after the tag and a dot. */
  readonly headline: string
  /** Shown on learn more, bold above the points; '' when the seat gave none. */
  readonly title: string
  /** Shown on learn more as bullets, the last one the action; three to six, at most MAX_POINTS. */
  readonly points: readonly string[]
  readonly seat: string
  /** The model the seat ran, as the runner resolved it; '' when it named none. */
  readonly model: string
  readonly payloadBytes: number
  readonly elapsedMs: number
}

declare module 'claude-code' {
  interface PluginState {
    'claude-council': { headsUp: StoredSession }
  }
}
