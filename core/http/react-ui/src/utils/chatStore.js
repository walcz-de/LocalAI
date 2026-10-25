// The browser cache of the Chat page's conversations. Chat writes it, Home
// reads it.
//
// Signed in, every account has its own entry: a draft one account could not
// upload must never be found, and uploaded, by the next account that signs in
// on the same browser. Without an account (auth disabled) the original key is
// used, so existing browser-only histories keep working.
//
// Besides the chats the entry holds `pendingDeletes`: ids the user deleted
// that the server has not confirmed yet ('*' = delete all). They survive a
// reload and are sent again until the server answers.

export const CHATS_STORAGE_KEY = 'localai_chats_data'

export function chatsStorageKey(accountId) {
  return accountId ? `${CHATS_STORAGE_KEY}:${accountId}` : CHATS_STORAGE_KEY
}

export function isChatsStorageKey(key) {
  return key === CHATS_STORAGE_KEY || (typeof key === 'string' && key.startsWith(`${CHATS_STORAGE_KEY}:`))
}

export function readChatStore(key) {
  try {
    const raw = localStorage.getItem(key)
    if (!raw) return null
    const data = JSON.parse(raw)
    if (!data || !Array.isArray(data.chats)) return null
    // Older chats stored a separate reasoningOff flag. It now means
    // reasoning_effort 'none'.
    const chats = data.chats.map(({ reasoningOff, ...chat }) => (
      reasoningOff ? { ...chat, reasoningEffort: 'none' } : chat
    ))
    return { ...data, chats, pendingDeletes: Array.isArray(data.pendingDeletes) ? data.pendingDeletes : [] }
  } catch {
    return null
  }
}

export function writeChatStore(key, data) {
  try {
    localStorage.setItem(key, JSON.stringify({ ...data, lastSaved: Date.now() }))
    return true
  } catch (err) {
    if (err?.name === 'QuotaExceededError' || err?.code === 22) {
      console.warn('localStorage quota exceeded')
    }
    return false
  }
}

// Inline media in the cache.
//
// Pictures, audio and video are part of a message as data: URLs (base64), so
// a few of them fill the few megabytes localStorage allows. A full cache used
// to fail silently: the chats then lived only in memory and were gone after a
// reload. So the cache keeps a placeholder instead of the bytes where it can
// afford to - for chats whose current state the server holds - and, when even
// that does not fit, the text of every chat rather than nothing.

export const OMITTED_MEDIA = 'omitted_media'
const MEDIA_PARTS = ['image_url', 'audio_url', 'video_url']

function placeholderFor(part) {
  if (!part || !MEDIA_PARTS.includes(part.type)) return null
  const url = part[part.type]?.url
  if (typeof url !== 'string' || !url.startsWith('data:')) return null
  const mime = url.slice(5, url.indexOf(';') > 0 ? url.indexOf(';') : 5)
  return { type: OMITTED_MEDIA, kind: part.type, mime }
}

// The message list with every inline medium replaced by a placeholder. The
// same array comes back when there was nothing to replace.
export function withoutInlineMedia(history) {
  if (!Array.isArray(history)) return history
  let changed = false
  const out = history.map(message => {
    if (!Array.isArray(message?.content)) return message
    let touched = false
    const content = message.content.map(part => {
      const placeholder = placeholderFor(part)
      if (!placeholder) return part
      touched = true
      return placeholder
    })
    if (!touched) return message
    changed = true
    return { ...message, content }
  })
  return changed ? out : history
}

// Puts the media of `source` (the same conversation from the server) back
// where `history` only has placeholders. Positions must match: message i,
// part j, same kind of medium.
export function restoreOmittedMedia(history, source) {
  if (!Array.isArray(history) || !Array.isArray(source)) return history
  let changed = false
  const out = history.map((message, i) => {
    if (!Array.isArray(message?.content)) return message
    const from = source[i]?.content
    if (!Array.isArray(from)) return message
    let touched = false
    const content = message.content.map((part, j) => {
      if (part?.type !== OMITTED_MEDIA) return part
      const original = from[j]
      if (original?.type !== part.kind || !placeholderFor(original)) return part
      touched = true
      return original
    })
    if (!touched) return message
    changed = true
    return { ...message, content }
  })
  return changed ? out : history
}

// The message list as a model request needs it: placeholders carry no media
// and are left out.
export function withoutPlaceholders(history) {
  if (!Array.isArray(history)) return history
  return history.map(message => {
    if (!Array.isArray(message?.content) || !message.content.some(p => p?.type === OMITTED_MEDIA)) return message
    return { ...message, content: message.content.filter(p => p?.type !== OMITTED_MEDIA) }
  })
}

// Writes the Chat page's cache. `serverHolds(chat)` says whether the server
// has this exact state of the chat; those chats are cached without their
// media. When the cache does not fit, every chat is written without media.
// Returns 'full' or 'text' for what was written, or false when nothing could
// be written.
export function writeChatCache(key, data, serverHolds = () => false) {
  const strip = chat => {
    const history = withoutInlineMedia(chat.history)
    return history === chat.history ? chat : { ...chat, history }
  }
  const chats = data.chats.map(chat => (serverHolds(chat) ? strip(chat) : chat))
  if (writeChatStore(key, { ...data, chats })) return 'full'
  if (writeChatStore(key, { ...data, chats: data.chats.map(strip) })) return 'text'
  return false
}
