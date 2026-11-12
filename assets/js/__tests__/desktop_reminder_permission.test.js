/**
 * The calendar settings' desktop-reminder controls ask the browser for
 * notification permission from inside the click, not from a render, and report
 * the answer to the server, which saves the preference only for "granted".
 */

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest"
import {
  DesktopReminderPermission,
  currentPermission,
  requestPermission,
} from "../hooks/desktop_reminder_permission"

function mountHook({ checked = false, role = "switch" } = {}) {
  const el = document.createElement("button")
  if (role === "switch") el.setAttribute("aria-checked", String(checked))
  el.dataset.reportEvent = "desktop_reminders_permission"
  el.dataset.enableEvent = "enable_desktop_reminders"
  document.body.appendChild(el)

  const pushEventTo = vi.fn()
  const hook = Object.assign(Object.create(DesktopReminderPermission), { el, pushEventTo })
  hook.mounted()
  return { hook, el, pushEventTo }
}

// A click that the LiveView's window listener would see unless stopped.
function click(el) {
  const reachedWindow = vi.fn()
  window.addEventListener("click", reachedWindow, { once: true })
  el.click()
  window.removeEventListener("click", reachedWindow)
  return reachedWindow
}

describe("DesktopReminderPermission", () => {
  beforeEach(() => {
    document.body.innerHTML = ""
    global.Notification = { permission: "default", requestPermission: vi.fn() }
  })

  afterEach(() => {
    delete global.Notification
  })

  test("reports the current permission when it mounts", () => {
    global.Notification.permission = "denied"
    const { pushEventTo } = mountHook()

    expect(pushEventTo).toHaveBeenCalledWith(expect.anything(), "desktop_reminders_permission", {
      permission: "denied",
    })
  })

  test("reports an unsupported browser", () => {
    delete global.Notification
    const { pushEventTo } = mountHook()

    expect(pushEventTo).toHaveBeenCalledWith(expect.anything(), "desktop_reminders_permission", {
      permission: "unsupported",
    })
  })

  test("turning on asks inside the click, stops the plain toggle and pushes the answer", async () => {
    global.Notification.requestPermission = vi.fn(() => Promise.resolve("granted"))
    const { el, pushEventTo } = mountHook({ checked: false })
    pushEventTo.mockClear()

    const reachedWindow = click(el)

    // Called synchronously by the click, not after an await.
    expect(global.Notification.requestPermission).toHaveBeenCalledTimes(1)
    // The plain phx-click toggle never sees it: it would save "on" regardless.
    expect(reachedWindow).not.toHaveBeenCalled()

    await vi.waitFor(() =>
      expect(pushEventTo).toHaveBeenCalledWith(el, "enable_desktop_reminders", {
        permission: "granted",
      })
    )
  })

  test("a refusal is pushed as such, never as a toggle", async () => {
    global.Notification.requestPermission = vi.fn(() => Promise.resolve("denied"))
    const { el, pushEventTo } = mountHook({ checked: false })
    pushEventTo.mockClear()

    click(el)

    await vi.waitFor(() =>
      expect(pushEventTo).toHaveBeenCalledWith(el, "enable_desktop_reminders", {
        permission: "denied",
      })
    )
  })

  test("turning off is left to the ordinary toggle", () => {
    const { el, pushEventTo } = mountHook({ checked: true })
    pushEventTo.mockClear()

    const reachedWindow = click(el)

    expect(global.Notification.requestPermission).not.toHaveBeenCalled()
    expect(reachedWindow).toHaveBeenCalled()
    expect(pushEventTo).not.toHaveBeenCalled()
  })

  test("the grant button (no aria-checked) asks for permission", async () => {
    global.Notification.requestPermission = vi.fn(() => Promise.resolve("granted"))
    const { el, pushEventTo } = mountHook({ role: "button" })
    pushEventTo.mockClear()

    click(el)

    expect(global.Notification.requestPermission).toHaveBeenCalledTimes(1)
    await vi.waitFor(() => expect(pushEventTo).toHaveBeenCalledTimes(1))
  })

  test("stops listening when destroyed", () => {
    const { hook, el } = mountHook({ checked: false })
    hook.destroyed()

    click(el)

    expect(global.Notification.requestPermission).not.toHaveBeenCalled()
  })
})

describe("requestPermission", () => {
  afterEach(() => {
    delete global.Notification
  })

  test("copes with the callback form older Safari uses", async () => {
    global.Notification = {
      permission: "default",
      requestPermission: (callback) => callback("granted"),
    }

    await expect(requestPermission()).resolves.toBe("granted")
  })

  test("falls back to the current permission when the request throws", async () => {
    global.Notification = {
      permission: "denied",
      requestPermission: () => {
        throw new Error("blocked")
      },
    }

    await expect(requestPermission()).resolves.toBe("denied")
    expect(currentPermission()).toBe("denied")
  })

  test("says unsupported when there is no Notification API", async () => {
    await expect(requestPermission()).resolves.toBe("unsupported")
  })
})
