import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { DesktopReminders, selectDue } from "../hooks/desktop_reminders"

function makeHook(feed, { enabled = true } = {}) {
  const el = document.createElement("div")
  el.dataset.enabled = String(enabled)
  el.dataset.reminders = JSON.stringify(feed)
  const hook = Object.assign(Object.create(DesktopReminders), { el })
  return { hook, el }
}

describe("selectDue", () => {
  it("returns entries whose fire instant is in (last, now]", () => {
    const feed = [
      { key: "a", fire_at_ms: 100 },
      { key: "b", fire_at_ms: 200 },
      { key: "c", fire_at_ms: 300 },
    ]
    // half-open: 100 excluded (== last), 200 included (== now), 300 excluded
    expect(selectDue(feed, 100, 200).map((e) => e.key)).toEqual(["b"])
  })
})

describe("DesktopReminders hook", () => {
  let now

  beforeEach(() => {
    now = 1_700_000_000_000
    vi.spyOn(Date, "now").mockImplementation(() => now)
    // Fake only interval timers so the manual Date.now spy stays in control.
    vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] })
    global.Notification = vi.fn()
    global.Notification.permission = "granted"
    global.Notification.requestPermission = vi.fn(() => Promise.resolve("granted"))
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    delete global.Notification
  })

  it("fires a notification for a reminder that just became due", () => {
    const { hook } = makeHook([
      { key: "k1", fire_at_ms: now - 1000, title: "Reminder: Standup", body: "Today at 3:00 PM" },
    ])

    hook.mounted()

    expect(global.Notification).toHaveBeenCalledTimes(1)
    expect(global.Notification).toHaveBeenCalledWith("Reminder: Standup", {
      body: "Today at 3:00 PM",
      tag: "k1",
    })
    hook.destroyed()
  })

  it("does not fire the same reminder twice across ticks", () => {
    const { hook } = makeHook([{ key: "k1", fire_at_ms: now - 1000, title: "t", body: "b" }])

    hook.mounted()
    now += 30000
    vi.advanceTimersByTime(30000)

    expect(global.Notification).toHaveBeenCalledTimes(1)
    hook.destroyed()
  })

  it("does nothing when the preference is disabled", () => {
    const { hook } = makeHook([{ key: "k1", fire_at_ms: now - 1000, title: "t", body: "b" }], {
      enabled: false,
    })

    hook.mounted()

    expect(global.Notification).not.toHaveBeenCalled()
    hook.destroyed()
  })

  it("requests permission but does not fire when permission is not granted", () => {
    global.Notification.permission = "default"
    const { hook } = makeHook([{ key: "k1", fire_at_ms: now - 1000, title: "t", body: "b" }])

    hook.mounted()

    expect(global.Notification.requestPermission).toHaveBeenCalled()
    // The constructor itself is never invoked (only the static helpers were).
    expect(global.Notification).not.toHaveBeenCalled()
    hook.destroyed()
  })

  it("fires reminders from a feed delivered after mount", () => {
    const { hook, el } = makeHook([])
    hook.mounted()
    expect(global.Notification).not.toHaveBeenCalled()

    el.dataset.reminders = JSON.stringify([
      { key: "k2", fire_at_ms: now + 15000, title: "t2", body: "b2" },
    ])
    hook.updated()

    now += 30000
    vi.advanceTimersByTime(30000)

    expect(global.Notification).toHaveBeenCalledWith("t2", { body: "b2", tag: "k2" })
    hook.destroyed()
  })
})
