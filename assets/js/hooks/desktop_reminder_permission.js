// desktop_reminder_permission.js
// LiveView hook for the calendar settings' "Desktop reminders" controls.
//
// Notification.requestPermission() must run inside a user gesture: Firefox
// (since 72) and Safari ignore a request made from anywhere else, and Chrome
// shows its prompt out of the blue. So the request is made here, in the click
// that turns reminders on, and the server saves the preference as on only once
// the browser has said "granted".
//
// The hook sits on two elements: the switch (which has aria-checked) and the
// "Allow notifications" button shown for a preference saved before this
// existed. Clicking the switch while it is on is the ordinary toggle, left to
// phx-click. Any other click is a request for permission: it stops the plain
// toggle (which would save "on" whatever the browser answers), asks, and
// pushes the answer to the component named by `data-enable-event`.
//
// On mount it also reports the current permission (`data-report-event`) so the
// modal can say when notifications are blocked, which the server cannot know.

export function currentPermission() {
  return typeof Notification === "undefined" ? "unsupported" : Notification.permission
}

// Resolves with the permission the browser settled on. Older Safari takes a
// callback and returns nothing; modern browsers return a promise.
export function requestPermission() {
  if (typeof Notification === "undefined") return Promise.resolve("unsupported")

  return new Promise((resolve) => {
    try {
      const result = Notification.requestPermission(resolve)
      if (result && typeof result.then === "function") result.then(resolve, () => resolve(currentPermission()))
    } catch (_e) {
      resolve(currentPermission())
    }
  })
}

export const DesktopReminderPermission = {
  mounted() {
    this._onClick = (event) => {
      if (this.el.getAttribute("aria-checked") === "true") return

      event.stopPropagation()
      const enableEvent = this.el.dataset.enableEvent
      // The request is made synchronously inside the click; only the answer is awaited.
      requestPermission().then((permission) => {
        this.pushEventTo(this.el, enableEvent, { permission })
      })
    }
    this.el.addEventListener("click", this._onClick)

    this.pushEventTo(this.el, this.el.dataset.reportEvent, { permission: currentPermission() })
  },

  destroyed() {
    this.el.removeEventListener("click", this._onClick)
  },
}
