/**
 * Server URL field: accepts an address typed without its scheme.
 *
 * Every self-hosted integration asks for a server URL, and the most natural
 * thing to type is the bare host (`cloud.example.com`). The input keeps
 * `type="url"`, so the browser's own constraint check still runs and still
 * blocks the submit: dropping the type, or putting `novalidate` on the form,
 * would switch off the `required` check on every other field in it too. What
 * this hook changes is what happens inside that constraint, and it changes it
 * for this one input only:
 *
 *  - On `change` (the value being committed, which happens before `blur` and
 *    before an implicit submit), an address with no scheme gains `https://`:
 *    the same prefix the server applies before it stores one. The corrected
 *    value is written back into the field, so what gets saved is what the
 *    person can see, rather than a silent rewrite on the way to the database.
 *  - On `invalid`, a type mismatch gets Tymeslot's wording instead of the
 *    browser's "Please enter a URL", which names neither the field nor the
 *    correction. An empty required field is left alone: the browser's own
 *    "please fill in this field" already says the right thing.
 *  - On `input`, the custom message is cleared, or a corrected value would
 *    keep failing on the message it was corrected for.
 */

/**
 * Prefix `https://` onto an address that carries no scheme.
 *
 * Mirrors `Tymeslot.Integrations.Shared.InputValidators.normalize_url_protocol/1`
 * so the field shows exactly what the server will store. A value that already
 * names a scheme is left alone, wrong scheme included, so that `ftp://…` still
 * earns the message about which schemes are allowed instead of being quietly
 * turned into something else.
 *
 * @param {string} value raw field value
 * @returns {string} the value with a scheme, trimmed
 */
export function normaliseUrlScheme(value) {
  const trimmed = (value || "").trim();

  if (trimmed === "" || trimmed.includes("://")) return trimmed;

  return trimmed.startsWith("//") ? `https:${trimmed}` : `https://${trimmed}`;
}

export const ServerUrlField = {
  mounted() {
    this.onChange = () => this.applyScheme();
    this.onInvalid = () => this.explainTypeMismatch();
    this.onInput = () => this.el.setCustomValidity("");

    this.el.addEventListener("change", this.onChange);
    this.el.addEventListener("invalid", this.onInvalid);
    this.el.addEventListener("input", this.onInput);
  },

  updated() {
    // A patch can replace the value under us. A custom error left over from
    // the previous one would then refuse a value nobody was told was wrong.
    this.el.setCustomValidity("");
  },

  destroyed() {
    this.el.removeEventListener("change", this.onChange);
    this.el.removeEventListener("invalid", this.onInvalid);
    this.el.removeEventListener("input", this.onInput);
  },

  applyScheme() {
    const corrected = normaliseUrlScheme(this.el.value);
    if (corrected === this.el.value) return;

    this.el.value = corrected;
    this.el.setCustomValidity("");
  },

  explainTypeMismatch() {
    if (!this.el.validity.typeMismatch) return;

    this.el.setCustomValidity(this.el.dataset.schemeHint || "");
  },
};
