/**
 * Keep unsaved SMTP credentials in their inputs across LiveView validation.
 *
 * The server deliberately renders empty credential values. Copy only the
 * current DOM value into the incoming patch, leaving validation and disabled
 * attributes under server control. A per-input hook is insufficient because
 * LiveView skips its beforeUpdate callback when the markup is unchanged.
 * New input ids on submission or settings reload prevent this copy so those
 * operations still clear credentials. No value is cached outside the DOM.
 *
 * @param {Element} fromEl the current element
 * @param {Element} toEl the incoming detached element
 * @returns {void}
 */
export function preserveSmtpCredentialValue(fromEl, toEl) {
  const selector = 'input[data-smtp-credential]';

  if (fromEl.id && fromEl.id === toEl.id &&
      fromEl.matches(selector) && toEl.matches(selector)) {
    toEl.value = fromEl.value;
  }
}
