/**
 * Share link: the onboarding live step's "Send them your link" button.
 *
 * The message is built on the server and carried in `data-share-text`, with
 * the booking URL in `data-share-url` and a mail subject in
 * `data-share-subject`. On click:
 *
 *   - Where the device has a share sheet (`navigator.share`, and
 *     `navigator.canShare` does not refuse the data), it opens it. Settling
 *     the promise counts as a keep (`share_sheet`): most platforms settle on
 *     completion, some as soon as the sheet opens, and either will do. An
 *     `AbortError` (the sheet dismissed) counts as nothing; any other error
 *     falls through to the mail client.
 *   - Otherwise it opens a new message in the mail client (`mailto:`), which
 *     counts as `first_person`.
 *
 * It also answers the server's `share_link:focus` event, sent when the host
 * presses the locked "Go to dashboard": the button takes the focus and its
 * card pulses once (not under reduced motion; that is the stylesheet's).
 */

/**
 * The `mailto:` address for a message, with both parts percent-encoded so
 * spaces read as spaces (a form-encoded `+` shows literally in some clients).
 *
 * @param {string} subject
 * @param {string} body
 * @returns {string}
 */
export function mailtoHref(subject, body) {
  return `mailto:?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`
}

/**
 * Whether to offer the share sheet for `data`.
 *
 * @param {Navigator} nav
 * @param {{text: string, url: string}} data
 * @returns {boolean}
 */
export function canUseShareSheet(nav, data) {
  if (typeof nav.share !== "function") return false
  if (typeof nav.canShare !== "function") return true
  return nav.canShare(data) !== false
}

const PULSE_CLASS = "onboarding-keep-pulse"

export const ShareLink = {
  mounted() {
    this.onClick = (event) => {
      event.preventDefault()
      if (this.el.disabled) return
      this.share()
    }
    this.el.addEventListener("click", this.onClick)

    this.handleEvent("share_link:focus", () => this.focusAndPulse())
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },

  async share() {
    const text = this.el.dataset.shareText || ""
    const url = this.el.dataset.shareUrl || ""
    const data = { text, url }

    if (canUseShareSheet(navigator, data)) {
      try {
        await navigator.share(data)
        this.pushEvent("keep_link", { method: "share_sheet" })
        return
      } catch (error) {
        if (error && error.name === "AbortError") return
      }
    }

    this.openMail(text)
  },

  openMail(text) {
    const link = document.createElement("a")
    link.href = mailtoHref(this.el.dataset.shareSubject || "", text)
    link.click()
    this.pushEvent("keep_link", { method: "first_person" })
  },

  focusAndPulse() {
    this.el.focus()

    const card = this.el.closest(".onboarding-keep-card")
    if (!card) return

    card.classList.remove(PULSE_CLASS)
    // Restart the animation if it is still running from a previous press.
    void card.offsetWidth
    card.classList.add(PULSE_CLASS)
    card.addEventListener("animationend", () => card.classList.remove(PULSE_CLASS), { once: true })
  }
}

/**
 * Stage iframe: marks the host's real page as loaded (`data-loaded`), which
 * is what switches the live stage on. The element is rendered with
 * `JS.ignore_attributes(["data-loaded"])`, so a patch keeps the mark.
 */
export const StageIframe = {
  mounted() {
    this.onLoad = () => this.el.setAttribute("data-loaded", "")
    this.el.addEventListener("load", this.onLoad)
  },

  destroyed() {
    this.el.removeEventListener("load", this.onLoad)
  }
}
