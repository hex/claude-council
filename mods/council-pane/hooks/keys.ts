// ABOUTME: The provider API keys a person can store in the plugin's config, and the variable each one becomes
// ABOUTME: Option names match plugin.json's sensitive userConfig; a missing, blank or mistyped value is no key

export const PROVIDER_KEYS = [
  { option: 'gemini_api_key', variable: 'GEMINI_API_KEY', title: 'Gemini API key' },
  { option: 'openai_api_key', variable: 'OPENAI_API_KEY', title: 'OpenAI API key' },
  { option: 'xai_api_key', variable: 'XAI_API_KEY', title: 'xAI API key (Grok)' },
  { option: 'perplexity_api_key', variable: 'PERPLEXITY_API_KEY', title: 'Perplexity API key' },
  { option: 'kimi_api_key', variable: 'KIMI_API_KEY', title: 'Kimi API key' },
  { option: 'openrouter_api_key', variable: 'OPENROUTER_API_KEY', title: 'OpenRouter API key' },
] as const

export type KeyVariable = (typeof PROVIDER_KEYS)[number]['variable']

export type StoredKey = { variable: KeyVariable; value: string }

export function storedKeys(options: Record<string, unknown>): StoredKey[] {
  return PROVIDER_KEYS.flatMap(({ option, variable }) => {
    const value = options[option]
    return typeof value === 'string' && value.trim() !== '' ? [{ variable, value }] : []
  })
}
