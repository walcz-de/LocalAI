import { test, expect } from './coverage-fixtures.js'
import { mockChat, answerWith, CHATS_KEY } from './chat-fixtures.js'

// Chats must not get lost on a reload (docs/content/features/chat-history.md).
// Recorded failure: the conversation list answered 503 once while the server
// was starting, the browser storage was nearly full, and the chat had a
// 1.26 MB photo in it. The Chat page turned server sync off for the whole
// visit after the one failed list, the browser cache could not hold the
// picture, so the chat lived only in memory - and was gone after a reload.

const ALICE = { id: 'u-alice', name: 'Alice', email: 'alice@example.com', role: 'admin', permissions: {} }
const aliceKey = `${CHATS_KEY}:${ALICE.id}`
const PROMPT = 'Reifendruck-Test'
const ANSWER = 'Antwort-OK'

// Incompressible bytes of the recorded size (base64: ~1.68M characters).
function photoBytes(size = 1_260_000) {
  const buf = Buffer.alloc(size)
  let x = 0x9456
  for (let i = 0; i < size; i++) {
    x = (x * 1103515245 + 12345) >>> 0
    buf[i] = x >>> 24
  }
  return buf
}
const PHOTO = { name: 'IMG.HEIC', mimeType: 'image/heic', buffer: photoBytes() }
const PHOTO_URL = `data:image/heic;base64,${PHOTO.buffer.toString('base64')}`

async function signedInAsAlice(page) {
  await page.route('**/api/auth/status', route => route.fulfill({
    json: { authEnabled: true, staticApiKeyRequired: false, providers: ['local'], hasUsers: true, user: ALICE },
  }))
}

// /api/conversations with the server's contract. `failLists` answers the
// first N list requests with 503, as a server that is still starting.
async function fakeServer(page, { failLists = 0 } = {}) {
  const live = new Map()
  let lists = 0
  let version = 0
  await page.route(/\/api\/conversations(\/[^?]*)?(\?.*)?$/, async (route) => {
    const req = route.request()
    const path = new URL(req.url()).pathname
    const rest = path.slice(path.indexOf('/api/conversations') + '/api/conversations'.length)
    const id = rest.startsWith('/') ? decodeURIComponent(rest.slice(1)) : null
    if (req.method() === 'GET' && !id) {
      lists++
      if (lists <= failLists) return route.fulfill({ status: 503, json: { error: 'starting' } })
      return route.fulfill({ json: { conversations: [...live.values()], deleted: [] } })
    }
    if (req.method() === 'PUT' && id) {
      const saved = { ...req.postDataJSON(), id, version: ++version }
      live.set(id, saved)
      return route.fulfill({ json: saved })
    }
    return route.fulfill({ status: 404, json: { error: 'not found' } })
  })
  return {
    lists: () => lists,
    // The stored conversation that holds the prompt, if any.
    chatWith: (text) => [...live.values()].find(c => JSON.stringify(c.history || []).includes(text)) || null,
  }
}

// Fill localStorage to its quota, then free `free` characters - a stand-in for
// a chat cache full of earlier pictures.
async function fillStorage(page, free) {
  await page.evaluate((room) => {
    let lo = 0
    let hi = 20e6
    while (hi - lo > 1000) {
      const mid = Math.floor((lo + hi) / 2)
      try { localStorage.setItem('zz-filler', 'x'.repeat(mid)); lo = mid } catch { hi = mid }
    }
    localStorage.setItem('zz-filler', 'x'.repeat(Math.max(0, lo - room)))
  }, free)
}

// Client-side navigation to Chat, so the visit (and its list request) is the
// same one the storage was filled in.
async function openChatInApp(page) {
  await page.evaluate(() => { history.pushState({}, '', '/app/chat'); dispatchEvent(new PopStateEvent('popstate')) })
  await page.getByTestId('chat-composer').waitFor({ timeout: 15_000 })
}

async function sendWithPhoto(page, { image = true } = {}) {
  const composer = page.getByTestId('chat-composer')
  if (image) {
    await composer.locator('input[type=file][accept="image/*"]').setInputFiles(PHOTO)
    await expect(composer.locator('.home-file-tag', { hasText: PHOTO.name })).toBeVisible()
  }
  await page.getByTestId('chat-input').fill(PROMPT)
  await page.getByTestId('chat-input').press('Enter')
  await expect(page.getByText(ANSWER)).toBeVisible()
}

// After a reload: the conversation with its photo and its answer is there.
async function expectChatAfterReload(page) {
  await page.goto('/app/chat')
  await page.getByTestId('chat-composer').waitFor()
  await expect(page.getByText(ANSWER)).toBeVisible({ timeout: 15_000 })
  await expect(page.getByText(PROMPT).first()).toBeVisible()
  await expect(page.locator('.cx-thumb img')).toHaveAttribute('src', PHOTO_URL)
}

async function start(page, { failLists, storageFree }) {
  await mockChat(page)
  await signedInAsAlice(page)
  const server = await fakeServer(page, { failLists })
  await answerWith(page, ANSWER)
  await page.goto('/app')
  await expect(page.locator('.home-greeting')).toBeVisible({ timeout: 15_000 })
  await page.evaluate(() => localStorage.clear())
  if (storageFree !== null) await fillStorage(page, storageFree)
  await openChatInApp(page)
  return server
}

test.describe('Chat history survives a reload', () => {
  test('X: list fails once, storage nearly full, photo: the chat reaches the server and survives a reload', async ({ page }) => {
    const server = await start(page, { failLists: 1, storageFree: 1e6 })
    await sendWithPhoto(page)
    // Uploaded once the server answers again - without a reload.
    await expect.poll(() => server.chatWith(PROMPT) !== null, { timeout: 20_000 }).toBe(true)
    await expect.poll(() => JSON.stringify(server.chatWith(PROMPT).history), { timeout: 10_000 }).toContain(ANSWER)
    expect(JSON.stringify(server.chatWith(PROMPT).history)).toContain(PHOTO_URL)
    await expectChatAfterReload(page)
  })

  test('Y: list ok, storage nearly full, photo: the chat survives a reload (counter-check)', async ({ page }) => {
    const server = await start(page, { failLists: 0, storageFree: 1e6 })
    await sendWithPhoto(page)
    await expect.poll(() => JSON.stringify(server.chatWith(PROMPT)?.history || ''), { timeout: 10_000 }).toContain(ANSWER)
    await expectChatAfterReload(page)
  })

  test('Z: list fails once, empty storage, photo: the chat survives a reload (counter-check)', async ({ page }) => {
    await start(page, { failLists: 1, storageFree: null })
    await sendWithPhoto(page)
    await page.waitForTimeout(1_000) // past the 500 ms save debounce
    await expectChatAfterReload(page)
  })

  test('a chat written while the list failed is uploaded once the server answers, without a reload', async ({ page }) => {
    const server = await start(page, { failLists: 1, storageFree: null })
    await sendWithPhoto(page, { image: false })
    await expect.poll(() => server.lists(), { timeout: 20_000 }).toBeGreaterThan(1)
    await expect.poll(() => JSON.stringify(server.chatWith(PROMPT)?.history || ''), { timeout: 10_000 }).toContain(ANSWER)
  })

  test('a list the server does not offer (404) is not asked for again (counter-check)', async ({ page }) => {
    await mockChat(page)
    await signedInAsAlice(page)
    let lists = 0
    await page.route(/\/api\/conversations(\/[^?]*)?(\?.*)?$/, route => {
      if (route.request().method() === 'GET') lists++
      return route.fulfill({ status: 404, json: { error: 'not found' } })
    })
    await answerWith(page, ANSWER)
    await page.goto('/app/chat')
    await page.getByTestId('chat-composer').waitFor()
    await page.getByTestId('chat-input').fill(PROMPT)
    await page.getByTestId('chat-input').press('Enter')
    await expect(page.getByText(ANSWER)).toBeVisible()
    await page.waitForTimeout(4_000)
    expect(lists).toBe(1)
    // The browser keeps the chat.
    const stored = await page.evaluate(k => JSON.parse(localStorage.getItem(k) || '{}'), aliceKey)
    expect(JSON.stringify(stored.chats)).toContain(ANSWER)
  })
})

test.describe('Chat browser cache', () => {
  test('signed in: a picture the server holds is kept out of the browser cache, and still shows after a reload', async ({ page }) => {
    const server = await start(page, { failLists: 0, storageFree: null })
    await sendWithPhoto(page)
    await expect.poll(() => JSON.stringify(server.chatWith(PROMPT)?.history || ''), { timeout: 10_000 }).toContain(ANSWER)
    // The cache keeps the text, not the picture.
    await expect.poll(async () => {
      const raw = await page.evaluate(k => localStorage.getItem(k) || '', aliceKey)
      return raw.includes(ANSWER) && !raw.includes(PHOTO.buffer.toString('base64').slice(0, 2000))
    }, { timeout: 10_000 }).toBe(true)
    await expectChatAfterReload(page)
  })

  test('not signed in: the picture stays in the browser cache, the only copy (counter-check)', async ({ page }) => {
    await mockChat(page)
    await answerWith(page, ANSWER)
    await page.goto('/app/chat')
    await page.getByTestId('chat-composer').waitFor()
    await sendWithPhoto(page)
    await page.waitForTimeout(1_000)
    await page.goto('/app/chat')
    await page.getByTestId('chat-composer').waitFor()
    await expect(page.getByText(ANSWER)).toBeVisible()
    await expect(page.locator('.cx-thumb img')).toHaveAttribute('src', PHOTO_URL)
  })
})

test.describe('Chat saves before the page goes away', () => {
  async function sendBrowserOnly(page) {
    await mockChat(page)
    await answerWith(page, ANSWER)
    await page.goto('/app/chat')
    await page.getByTestId('chat-composer').waitFor()
    await page.getByTestId('chat-input').fill(PROMPT)
    await page.getByTestId('chat-input').press('Enter')
    await expect(page.getByText(ANSWER)).toBeVisible()
  }

  test('reloading right after the answer keeps it', async ({ page }) => {
    await sendBrowserOnly(page)
    // Within the 500 ms save debounce.
    await page.reload()
    await page.getByTestId('chat-composer').waitFor()
    await expect(page.getByText(ANSWER)).toBeVisible()
  })

  test('leaving Chat right after the answer keeps it', async ({ page }) => {
    await sendBrowserOnly(page)
    await page.evaluate(() => { history.pushState({}, '', '/app'); dispatchEvent(new PopStateEvent('popstate')) })
    await expect(page.locator('.home-greeting')).toBeVisible()
    const stored = await page.evaluate(k => localStorage.getItem(k) || '', CHATS_KEY)
    expect(stored).toContain(ANSWER)
  })

  test('nothing is lost when the answer is saved after the debounce (counter-check)', async ({ page }) => {
    await sendBrowserOnly(page)
    await page.waitForTimeout(1_000)
    await page.reload()
    await page.getByTestId('chat-composer').waitFor()
    await expect(page.getByText(ANSWER)).toBeVisible()
  })
})

test.describe('Chat warns when a chat cannot be kept', () => {
  async function sendWithStorage(page, free) {
    await mockChat(page)
    await answerWith(page, ANSWER)
    await page.goto('/app')
    await expect(page.locator('.home-greeting')).toBeVisible({ timeout: 15_000 })
    await page.evaluate(() => localStorage.clear())
    await fillStorage(page, free)
    await openChatInApp(page)
    await page.getByTestId('chat-input').fill(PROMPT)
    await page.getByTestId('chat-input').press('Enter')
    await expect(page.getByText(ANSWER)).toBeVisible()
  }

  test('no server and no room in the browser: a warning says the chat will be lost', async ({ page }) => {
    await sendWithStorage(page, 0)
    await expect(page.getByTestId('chat-unsaved-warning')).toBeVisible({ timeout: 5_000 })
  })

  test('room in the browser: no warning (counter-check)', async ({ page }) => {
    await sendWithStorage(page, 1e6)
    await page.waitForTimeout(1_500)
    await expect(page.getByTestId('chat-unsaved-warning')).toHaveCount(0)
  })
})
