// ABOUTME: A provider's models under a filter box, for the settings panel and the council picker
// ABOUTME: The caller builds each row; the list filters, orders and caps them
// The most rows drawn at once: OpenRouter lists hundreds of models, and the
// filter narrows them to the ones wanted.
const MODEL_ROWS_MAX = 300

// A filter box over `ids` and the list it narrows. `pinned(id)` keeps an id
// shown, ahead of the rest, whatever the filter says (what is chosen);
// `row(id)` builds its row; `empty` is said when nothing matches. Returns
// both elements, for the caller to place.
function modelList({ ids, pinned, row, label, empty, disabled }) {
  const filter = element('input', { type: 'search', placeholder: 'Filter models, for example deepseek', disabled: Boolean(disabled) })
  filter.setAttribute('aria-label', label)
  const list = element('div', { className: 'models' })
  function draw() {
    const needle = filter.value.trim().toLowerCase()
    const shown = ids.filter(id => pinned(id) || id.toLowerCase().includes(needle))
    shown.sort((a, b) => Number(pinned(b)) - Number(pinned(a)) || a.localeCompare(b))
    if (shown.length === 0) return list.replaceChildren(element('p', { className: 'note empty', textContent: empty }))
    list.replaceChildren(...shown.slice(0, MODEL_ROWS_MAX).map(row))
  }
  filter.addEventListener('input', draw)
  draw()
  return { filter, list }
}
