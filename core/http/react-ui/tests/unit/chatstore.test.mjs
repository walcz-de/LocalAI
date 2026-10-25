import test from 'node:test'
import assert from 'node:assert/strict'
import {
  OMITTED_MEDIA, writeChatCache, readChatStore, withoutInlineMedia, restoreOmittedMedia, withoutPlaceholders,
} from '../../src/utils/chatStore.js'

// A localStorage stand-in with a quota in characters, counted the way the
// browsers do (key + value), that throws QuotaExceededError like they do.
function storageWithQuota(quota) {
  const items = new Map()
  const used = () => [...items].reduce((n, [k, v]) => n + k.length + v.length, 0)
  return {
    items,
    getItem: (k) => (items.has(k) ? items.get(k) : null),
    setItem: (k, v) => {
      const value = String(v)
      const without = used() - (items.has(k) ? k.length + items.get(k).length : 0)
      if (without + k.length + value.length > quota) {
        throw new DOMException('The quota has been exceeded.', 'QuotaExceededError')
      }
      items.set(k, value)
    },
    removeItem: (k) => { items.delete(k) },
  }
}

const KEY = 'localai_chats_data:u-alice'
// The recorded case: a 1.26 MB photo, ~1.68M characters as base64.
const PHOTO_URL = `data:image/heic;base64,${'Q'.repeat(1_680_000)}`
const photoMessage = (text = 'Reifendruck-Test') => ({
  role: 'user',
  content: [{ type: 'text', text }, { type: 'image_url', image_url: { url: PHOTO_URL } }],
  files: [{ name: 'IMG.HEIC', type: 'image' }],
})
const chat = (id, history, extra = {}) => ({ id, name: id, model: 'm', history, updatedAt: 1, ...extra })
const photoChat = (id) => chat(id, [photoMessage(), { role: 'assistant', content: 'Antwort-OK' }])

test('chat cache: with 1M characters free, a chat with the photo keeps its text instead of failing', () => {
  globalThis.localStorage = storageWithQuota(1_000_000)
  const result = writeChatCache(KEY, { chats: [photoChat('a')], activeChatId: 'a', pendingDeletes: [] })
  assert.equal(result, 'text')
  const stored = readChatStore(KEY)
  assert.equal(stored.activeChatId, 'a')
  const [user, answer] = stored.chats[0].history
  assert.equal(user.content[0].text, 'Reifendruck-Test')
  assert.deepEqual(user.content[1], { type: OMITTED_MEDIA, kind: 'image_url', mime: 'image/heic' })
  assert.deepEqual(user.files, [{ name: 'IMG.HEIC', type: 'image' }])
  assert.equal(answer.content, 'Antwort-OK')
})

test('chat cache: with room, a chat the server does not hold keeps its photo (counter-check)', () => {
  globalThis.localStorage = storageWithQuota(5_000_000)
  const result = writeChatCache(KEY, { chats: [photoChat('a')], activeChatId: 'a', pendingDeletes: [] }, () => false)
  assert.equal(result, 'full')
  assert.equal(readChatStore(KEY).chats[0].history[0].content[1].image_url.url, PHOTO_URL)
})

test('chat cache: a chat the server holds is cached without its media, the others with', () => {
  globalThis.localStorage = storageWithQuota(5_000_000)
  const result = writeChatCache(KEY, {
    chats: [photoChat('synced'), photoChat('draft')], activeChatId: 'draft', pendingDeletes: [],
  }, c => c.id === 'synced')
  assert.equal(result, 'full')
  const raw = globalThis.localStorage.getItem(KEY)
  // One copy of the photo: the draft's.
  assert.equal(raw.split(PHOTO_URL).length - 1, 1)
  const byId = Object.fromEntries(readChatStore(KEY).chats.map(c => [c.id, c]))
  assert.equal(byId.synced.history[0].content[1].type, OMITTED_MEDIA)
  assert.equal(byId.draft.history[0].content[1].image_url.url, PHOTO_URL)
})

test('chat cache: when not even the text fits, nothing is written and the caller is told', () => {
  globalThis.localStorage = storageWithQuota(50)
  assert.equal(writeChatCache(KEY, { chats: [photoChat('a')], activeChatId: 'a', pendingDeletes: [] }), false)
  assert.equal(globalThis.localStorage.getItem(KEY), null)
})

test('chat media: only inline data: media becomes a placeholder; text, links and unchanged lists stay', () => {
  const linked = { role: 'user', content: [{ type: 'image_url', image_url: { url: 'https://example.com/a.png' } }] }
  const plain = [{ role: 'user', content: 'hello' }, linked]
  assert.equal(withoutInlineMedia(plain), plain)
  const audio = { role: 'user', content: [{ type: 'audio_url', audio_url: { url: 'data:audio/wav;base64,AAAA' } }] }
  assert.deepEqual(withoutInlineMedia([audio])[0].content[0], { type: OMITTED_MEDIA, kind: 'audio_url', mime: 'audio/wav' })
})

test('chat media: placeholders are filled back from the server copy, position by position', () => {
  const server = [photoMessage(), { role: 'assistant', content: 'Antwort-OK' }]
  const cached = withoutInlineMedia(server)
  const edited = [...cached, { role: 'user', content: 'and now?' }]
  const restored = restoreOmittedMedia(edited, server)
  assert.equal(restored[0].content[1].image_url.url, PHOTO_URL)
  assert.equal(restored[2].content, 'and now?')
  // Counter-check: a source without that medium leaves the placeholder.
  const other = [{ role: 'user', content: [{ type: 'text', text: 'x' }, { type: 'text', text: 'y' }] }]
  assert.equal(restoreOmittedMedia(cached, other)[0].content[1].type, OMITTED_MEDIA)
})

test('chat media: a request never carries a placeholder', () => {
  const cached = withoutInlineMedia([photoMessage()])
  const forRequest = withoutPlaceholders(cached)
  assert.deepEqual(forRequest[0].content, [{ type: 'text', text: 'Reifendruck-Test' }])
  const untouched = [photoMessage()]
  assert.equal(withoutPlaceholders(untouched)[0], untouched[0])
})
