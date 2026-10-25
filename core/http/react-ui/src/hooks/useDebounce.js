import { useRef, useEffect, useCallback } from 'react'

/**
 * Returns a debounced version of the callback. Always calls the latest
 * version of fn (via ref), so callers don't need to memoize it.
 * Timer is cleaned up on unmount.
 */
export function useDebouncedCallback(fn, delay = 500) {
  const timerRef = useRef(null)
  const fnRef = useRef(fn)
  fnRef.current = fn

  useEffect(() => () => {
    if (timerRef.current) clearTimeout(timerRef.current)
  }, [])

  return useCallback((...args) => {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => fnRef.current(...args), delay)
  }, [delay])
}

/**
 * Runs a debounced effect: when deps change, waits `delay` ms before
 * calling fn. Resets the timer on each deps change.
 *
 * On unmount a pending call is dropped, unless `flushOnExit` is set: then it
 * runs at once - on unmount, and when the page is hidden or unloaded
 * (pagehide, visibilitychange to hidden). Use it for saves, so leaving the
 * page within the delay does not lose the last change.
 */
export function useDebouncedEffect(fn, deps, delay = 500, { flushOnExit = false } = {}) {
  const timerRef = useRef(null)
  const pendingRef = useRef(false)
  const fnRef = useRef(fn)
  fnRef.current = fn

  useEffect(() => {
    if (timerRef.current) clearTimeout(timerRef.current)
    pendingRef.current = true
    timerRef.current = setTimeout(() => {
      pendingRef.current = false
      fnRef.current()
    }, delay)
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)

  useEffect(() => {
    if (!flushOnExit) return undefined
    const flush = () => {
      if (!pendingRef.current) return
      pendingRef.current = false
      if (timerRef.current) clearTimeout(timerRef.current)
      fnRef.current()
    }
    const onHidden = () => { if (document.visibilityState === 'hidden') flush() }
    window.addEventListener('pagehide', flush)
    document.addEventListener('visibilitychange', onHidden)
    return () => {
      window.removeEventListener('pagehide', flush)
      document.removeEventListener('visibilitychange', onHidden)
      flush()
    }
  }, [flushOnExit])
}
