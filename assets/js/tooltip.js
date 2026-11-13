/**
 * Tooltip behaviour for the `<.tooltip>` component.
 *
 * Delegated from the document, so a tooltip added by a LiveView patch needs no
 * hook and no setup of its own. The bubble is a `popover`, opened in the top
 * layer so a card's `overflow`, a modal or `backdrop-filter` cannot clip it,
 * and placed from the control's position.
 *
 * - Hover (mouse, pen): opens after a short delay, closes when the pointer
 *   leaves both the control and the bubble.
 * - Keyboard focus (`:focus-visible`): opens at once, closes on blur.
 * - Escape: closes the open bubble and swallows the key, so it does not also
 *   close a modal behind it. The control stays closed until it is left.
 * - Touch: a tap toggles the bubble on a control that cannot act
 *   (aria-disabled, disabled, read-only, or no control at all); a control
 *   that does act shows it on a long press, since a tap is its action.
 *   An anchor marked `data-tooltip-isolated` keeps that tap to itself: its
 *   click goes no further, so a badge inside a clickable card shows its bubble
 *   without also opening the card.
 *
 * Scrolling or resizing moves the bubble with its control. A LiveView patch can strip the inline placement from an open bubble, so
 * the placement is restored from a small observer while it is open.
 */

const HOVER_DELAY = 120
const LONG_PRESS = 500
const GAP = 8
const MARGIN = 8

// A bare `tabindex` does not make something a control: an analytics bar is
// focusable only to read out its value, so a tap should show that value.
const ACTIONABLE =
  'button, a[href], input, select, textarea, [role="button"], [role="link"], [role="checkbox"], ' +
  '[role="switch"], [role="radio"], [role="tab"], [role="menuitem"], [role="option"]'

let open = null // { anchor, bubble, observer }
let showTimer = null
let pressTimer = null
let dismissed = null // anchor closed by Escape, until it is left
let swallowClick = false
let isolatedTap = null // anchor whose touch tap must not reach its ancestors

const anchorOf = (node) => node instanceof Element ? node.closest('[data-tooltip]') : null
const bubbleOf = (anchor) => anchor.querySelector(':scope > [role="tooltip"]')

function controlOf(anchor) {
  const control = anchor.querySelector(`:scope > :not([role="tooltip"])`)
  return control || anchor
}

/** Whether the trigger can act; only then does a long press take over a tap. */
export function isActionable(anchor) {
  const control = anchor.querySelector(`:scope > :not([role="tooltip"])`)
  if (!control) return false
  const target = control.matches(ACTIONABLE) ? control : control.querySelector(ACTIONABLE)
  if (!target) return false
  return !(target.matches('[aria-disabled="true"], :disabled') || target.readOnly === true)
}

function place(anchor, bubble) {
  const trigger = controlOf(anchor).getBoundingClientRect()
  const box = bubble.getBoundingClientRect()
  const roomAbove = trigger.top >= box.height + GAP + MARGIN
  const top = roomAbove ? trigger.top - box.height - GAP : trigger.bottom + GAP
  const centred = trigger.left + trigger.width / 2 - box.width / 2
  const maxLeft = window.innerWidth - box.width - MARGIN

  bubble.style.top = `${Math.round(top)}px`
  bubble.style.left = `${Math.round(Math.min(Math.max(centred, MARGIN), Math.max(maxLeft, MARGIN)))}px`
  bubble.dataset.side = roomAbove ? 'top' : 'bottom'
}

function show(anchor) {
  if (open && open.anchor === anchor) return
  hide()

  const bubble = bubbleOf(anchor)
  if (!bubble || !bubble.isConnected) return

  if (typeof bubble.showPopover === 'function' && !bubble.matches(':popover-open')) {
    bubble.showPopover()
  }
  place(anchor, bubble)

  const observer = new MutationObserver(() => {
    if (!bubble.style.top) place(anchor, bubble)
  })
  observer.observe(bubble, { attributes: true, attributeFilter: ['style'] })
  open = { anchor, bubble, observer }
}

function replaceOpen() {
  if (open && open.bubble.isConnected) place(open.anchor, open.bubble)
  else hide()
}

function hide() {
  clearTimeout(showTimer)
  showTimer = null
  if (!open) return

  const { bubble, observer } = open
  open = null
  observer.disconnect()
  bubble.style.top = ''
  bubble.style.left = ''
  if (bubble.isConnected && typeof bubble.hidePopover === 'function' && bubble.matches(':popover-open')) {
    bubble.hidePopover()
  }
}

function focusStaysWithin(anchor) {
  const active = document.activeElement
  return active && anchor.contains(active) && active.matches(':focus-visible')
}

function onPointerOver(event) {
  if (event.pointerType === 'touch') return
  const anchor = anchorOf(event.target)
  if (!anchor) return
  clearTimeout(showTimer)
  if (dismissed === anchor) return
  if (open && open.anchor === anchor) return
  showTimer = setTimeout(() => show(anchor), HOVER_DELAY)
}

function onPointerOut(event) {
  if (event.pointerType === 'touch') return
  const anchor = anchorOf(event.target)
  if (!anchor) return
  if (event.relatedTarget instanceof Node && anchor.contains(event.relatedTarget)) return

  clearTimeout(showTimer)
  if (dismissed === anchor) dismissed = null
  if (!focusStaysWithin(anchor)) {
    // A moment's grace, so the pointer can cross the gap onto the bubble.
    showTimer = setTimeout(hideIfLeft, HOVER_DELAY, anchor)
  }
}

function hideIfLeft(anchor) {
  if (open && open.anchor === anchor && !anchor.matches(':hover')) hide()
}

function onFocusIn(event) {
  const anchor = anchorOf(event.target)
  if (!anchor || dismissed === anchor) return
  if (event.target.matches(':focus-visible')) show(anchor)
}

function onFocusOut(event) {
  const anchor = anchorOf(event.target)
  if (!anchor) return
  if (event.relatedTarget instanceof Node && anchor.contains(event.relatedTarget)) return
  if (dismissed === anchor) dismissed = null
  if (open && open.anchor === anchor && !anchor.matches(':hover')) hide()
}

function onPointerDown(event) {
  swallowClick = false
  isolatedTap = null
  const anchor = anchorOf(event.target)

  if (event.pointerType !== 'touch') {
    // A click on the control: the bubble has done its job.
    if (anchor) hide()
    return
  }

  if (!anchor) {
    hide()
    return
  }

  if (isActionable(anchor)) {
    pressTimer = setTimeout(() => {
      if (!bubbleOf(anchor)) return
      swallowClick = true
      show(anchor)
    }, LONG_PRESS)
  } else {
    if (anchor.hasAttribute('data-tooltip-isolated')) isolatedTap = anchor
    if (open && open.anchor === anchor) hide()
    else show(anchor)
  }
}

function clearPress() {
  clearTimeout(pressTimer)
  pressTimer = null
}

function onClick(event) {
  const isolated = isolatedTap !== null && anchorOf(event.target) === isolatedTap
  isolatedTap = null
  if (!swallowClick && !isolated) return
  swallowClick = false
  event.preventDefault()
  event.stopPropagation()
}

function onContextMenu(event) {
  if (swallowClick && anchorOf(event.target)) {
    event.preventDefault()
    swallowClick = false
  }
}

function onKeyDown(event) {
  if (event.key !== 'Escape' || !open) return

  // Its control was removed by a patch: nothing is showing to dismiss.
  if (!open.bubble.isConnected) {
    hide()
    return
  }

  dismissed = open.anchor
  hide()
  event.stopPropagation()
  event.stopImmediatePropagation()
}

export function installTooltips(root = document) {
  // Capture phase on window for Escape, so an open bubble is closed before
  // the key reaches a modal's own Escape handling.
  window.addEventListener('keydown', onKeyDown, true)
  root.addEventListener('pointerover', onPointerOver)
  root.addEventListener('pointerout', onPointerOut)
  root.addEventListener('focusin', onFocusIn)
  root.addEventListener('focusout', onFocusOut)
  root.addEventListener('pointerdown', onPointerDown)
  root.addEventListener('pointerup', clearPress)
  root.addEventListener('pointercancel', clearPress)
  root.addEventListener('click', onClick, true)
  root.addEventListener('contextmenu', onContextMenu)
  window.addEventListener('scroll', replaceOpen, { capture: true, passive: true })
  window.addEventListener('resize', replaceOpen)

  return () => {
    hide()
    window.removeEventListener('keydown', onKeyDown, true)
    root.removeEventListener('pointerover', onPointerOver)
    root.removeEventListener('pointerout', onPointerOut)
    root.removeEventListener('focusin', onFocusIn)
    root.removeEventListener('focusout', onFocusOut)
    root.removeEventListener('pointerdown', onPointerDown)
    root.removeEventListener('pointerup', clearPress)
    root.removeEventListener('pointercancel', clearPress)
    root.removeEventListener('click', onClick, true)
    root.removeEventListener('contextmenu', onContextMenu)
    window.removeEventListener('scroll', replaceOpen, { capture: true })
    window.removeEventListener('resize', replaceOpen)
  }
}
