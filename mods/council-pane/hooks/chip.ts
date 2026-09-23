// ABOUTME: The band and pane chip: a label on a cell-by-cell colour gradient
// ABOUTME: with a light band that sweeps across it while something runs

export type ChipCell = { text: string; background: string }

// How far the sweep's centre, and the cell either side of it, move toward white.
const SWEEP = [0.28, 0.12]

const parse = (rgb: string) => (rgb.match(/\d+/g) ?? ['0', '0', '0']).map(Number)
const mix = (a: number[], b: number[], t: number) => a.map((v, i) => v + ((b[i] ?? 0) - v) * t)

// A stop list with one colour paints every cell that colour. `sweep` is the
// cell the light band is on; one past the chip draws it still.
export function chipCells(label: string, stops: string[], sweep?: number): ChipCell[] {
  const chars = [...` ${label} `]
  const colours = stops.map(parse)
  return chars.map((text, index) => {
    const t = chars.length > 1 ? index / (chars.length - 1) : 0
    const at = t * (colours.length - 1)
    const from = Math.min(Math.floor(at), colours.length - 1)
    let colour = mix(colours[from] ?? [0, 0, 0], colours[from + 1] ?? colours[from] ?? [0, 0, 0], at - from)
    const lift = sweep === undefined ? 0 : SWEEP[Math.abs(index - sweep)] ?? 0
    colour = mix(colour, [255, 255, 255], lift)
    return { text, background: `rgb(${colour.map(Math.round).join(',')})` }
  })
}
