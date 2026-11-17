// ABOUTME: Each provider's live model list for the settings panel: where to ask and how to read the answer
// ABOUTME: Parsing is pure so recorded responses can test it; a key is only ever sent to its own provider
'use strict'

const LIST_TIMEOUT_MS = 15 * 1000

// The one shape a model id may take. Ids end up in the council scripts'
// environment and OPENROUTER_MODELS is split on commas, so no comma, space or
// shell character gets through. OpenRouter's aliases start with a tilde.
const MODEL_ID = /^~?[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/

// Whether a value is a model id. Some scripts put the id in a URL path
// (gemini.sh), so its slash-separated parts must each be a real name: none
// empty, none `.` or `..`.
function isModelId(value) {
  return typeof value === 'string' && MODEL_ID.test(value) &&
    value.split('/').every(part => part !== '' && part !== '.' && part !== '..')
}

// Perplexity's Agent API takes these presets; it has no list endpoint to ask.
const PERPLEXITY_PRESETS = ['fast', 'low', 'medium', 'high', 'xhigh']

function bearer(key) {
  return { authorization: `Bearer ${key}` }
}

function dataIds(body) {
  if (!Array.isArray(body?.data)) throw new Error('the answer held no model list')
  return body.data.map(model => model.id)
}

// Gemini lists embedding and other models beside the ones that answer a
// question; only generateContent ones can sit on the council.
function geminiIds(body) {
  if (!Array.isArray(body?.models)) throw new Error('the answer held no model list')
  return body.models
    .filter(model => (model.supportedGenerationMethods ?? []).includes('generateContent'))
    .map(model => String(model.name).replace(/^models\//, ''))
}

const LISTS = {
  gemini: {
    url: 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000',
    headers: key => ({ 'x-goog-api-key': key }),
    ids: geminiIds,
  },
  openai: { url: 'https://api.openai.com/v1/models', headers: bearer, ids: dataIds },
  // xAI serves grok-latest, the scripts' default, without listing it.
  grok: { url: 'https://api.x.ai/v1/models', headers: bearer, ids: body => ['grok-latest', ...dataIds(body)] },
  kimi: { url: 'https://api.moonshot.ai/v1/models', headers: bearer, ids: dataIds },
  openrouter: { url: 'https://openrouter.ai/api/v1/models', headers: bearer, ids: dataIds },
}

// The ids a provider's list answer offers, in the order the panel shows them.
function modelIds(provider, body) {
  if (provider === 'perplexity') return PERPLEXITY_PRESETS
  const ids = LISTS[provider].ids(body).filter(isModelId)
  return [...new Set(ids)].sort()
}

async function listModels(provider, key) {
  if (provider === 'perplexity') return PERPLEXITY_PRESETS
  const list = LISTS[provider]
  // A redirect is an error, never followed: Gemini's key rides a header of
  // its own, which a redirect to another host would carry along.
  const response = await fetch(list.url, { headers: list.headers(key), redirect: 'error', signal: AbortSignal.timeout(LIST_TIMEOUT_MS) })
  if (!response.ok) throw new Error(`${new URL(list.url).host} answered HTTP ${response.status}`)
  return modelIds(provider, await response.json())
}

module.exports = { PERPLEXITY_PRESETS, isModelId, listModels, modelIds }
