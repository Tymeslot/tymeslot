/**
 * Share link: the onboarding live step's "Send them your link" button.
 *
 * The message is built on the server and carried in `data-share-text`, which
 * already ends with the booking URL, and a mail subject in
 * `data-share-subject`. The sheet is given the text alone: given the URL as
 * well, most targets paste it twice. On click:
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
 * @param {{text: string}} data
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
    const data = { text }

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
 * Stage iframe: the host's real page on the onboarding stage.
 *
 *   - Marks it loaded (`data-loaded`), which is what switches the live stage
 *     on.
 *   - Owns `src`: a reconnect renders a freshly signed preview token, and
 *     reloading the page for it would replay the switch-on and throw away a
 *     test booking in progress, so it loads `data-src` only when `data-page`
 *     (the page without its token) changes, as after a username change.
 *   - Below `lg` the stage card is a glimpse that takes no touch, so the frame
 *     leaves the tab order there (`tabindex="-1"`); the Expand modal's frame
 *     stays reachable.
 *
 * The element is rendered with `JS.ignore_attributes` for `data-loaded`,
 * `src` and `tabindex`, so a patch keeps what this sets.
 */
const NARROW_QUERY = "(max-width: 1023.98px)"

export const StageIframe = {
  mounted() {
    this.page = this.el.dataset.page
    this.onLoad = () => this.el.setAttribute("data-loaded", "")
    this.el.addEventListener("load", this.onLoad)

    this.media = window.matchMedia(NARROW_QUERY)
    this.onMedia = () => this.syncTabindex()
    this.media.addEventListener("change", this.onMedia)
    this.syncTabindex()
  },

  updated() {
    if (this.el.dataset.page !== this.page) {
      this.page = this.el.dataset.page
      this.el.removeAttribute("data-loaded")
      this.el.src = this.el.dataset.src
    }
    this.syncTabindex()
  },

  destroyed() {
    this.el.removeEventListener("load", this.onLoad)
    this.media.removeEventListener("change", this.onMedia)
  },

  syncTabindex() {
    const glimpse = this.media.matches && this.el.closest(".onboarding-stage") !== null
    if (glimpse) this.el.setAttribute("tabindex", "-1")
    else this.el.removeAttribute("tabindex")
  }
}
