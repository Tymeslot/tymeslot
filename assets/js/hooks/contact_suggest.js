/**
 * Contact suggest: offers the host's contacts under an invite field as they
 * type, from the address books of their calendar connections.
 *
 * The hook sits on an empty element beside the field (rendered by
 * `TymeslotWeb.Components.Dashboard.ContactSuggestions`, with
 * `phx-update="ignore"` so LiveView leaves the list alone) and names the
 * field in `data-input`. Listeners are delegated from the document and
 * matched by the field's id, so a field LiveView replaces keeps working.
 *
 * Suggestions come from `GET /dashboard/contacts/search?q=` (a plain
 * request, so a slow address book server never holds up the LiveView), asked
 * once typing pauses, for the term under the cursor.
 *
 * Choosing one, by mouse or with the arrow keys and Enter, fills it in as
 * the field's owner expects (`data-mode`):
 *   - `replace` (default): the field becomes the address. With
 *     `data-submit`, its form is then submitted (an "Add" form); with
 *     `data-name-input`, that field takes the contact's name when empty.
 *     Fields bound with `phx-blur` are told through a focusout, those in
 *     a `phx-change` form through an input event.
 *   - `append`: in a field of several addresses, the term being typed
 *     becomes `Name <address>, `.
 *
 * Accessibility: the field is a combobox (`role`, `aria-expanded`,
 * `aria-controls`, `aria-activedescendant`), the list a listbox of options,
 * and that suggestions are there is announced in a polite live region, in
 * the words the server rendered (`data-announce`).
 */

export const SEARCH_PATH = "/dashboard/contacts/search";
const DEBOUNCE_MS = 250;
const MIN_TERM = 2;

/**
 * The term being typed in `value` with the cursor at `caret`: the whole
 * value in `replace` mode, the text since the last comma, semicolon or line
 * break in `append` mode.
 */
export function currentTerm(value, caret, mode) {
  if (mode !== "append") return { term: value.trim(), start: 0, end: value.length };

  const before = value.slice(0, caret);
  const start = Math.max(before.lastIndexOf(","), before.lastIndexOf(";"), before.lastIndexOf("\n")) + 1;
  const afterCaret = value.slice(caret).search(/[,;\n]/);
  const end = afterCaret === -1 ? value.length : caret + afterCaret;

  return { term: value.slice(start, end).trim(), start, end };
}

/** A contact as `append` mode writes it. */
export function formatContact({ name, email }) {
  return name ? `${name.replace(/[<>,;"]/g, "").trim()} <${email}>` : email;
}

export const ContactSuggest = {
  mounted() {
    this.inputId = this.el.dataset.input;
    this.mode = this.el.dataset.mode || "replace";
    this.listId = `${this.inputId}-contact-suggestions`;
    this.contacts = [];
    this.active = -1;
    this.timer = null;
    this.request = 0;

    this.list = document.createElement("ul");
    this.list.id = this.listId;
    this.list.setAttribute("role", "listbox");
    this.list.hidden = true;
    this.list.className =
      "absolute z-50 mt-1 w-full max-h-64 overflow-auto rounded-token-md border border-tymeslot-200 bg-white shadow-lg text-token-sm";

    this.status = document.createElement("div");
    this.status.setAttribute("role", "status");
    this.status.setAttribute("aria-live", "polite");
    this.status.className = "sr-only";

    this.el.classList.add("relative");
    this.el.append(this.list, this.status);

    this.onInput = (e) => e.target.id === this.inputId && this.schedule(e.target);
    this.onKeydown = (e) => e.target.id === this.inputId && this.keydown(e);
    this.onFocusout = (e) => e.target.id === this.inputId && setTimeout(() => this.close(), 150);

    document.addEventListener("input", this.onInput);
    document.addEventListener("keydown", this.onKeydown, true);
    document.addEventListener("focusout", this.onFocusout);
  },

  destroyed() {
    clearTimeout(this.timer);
    document.removeEventListener("input", this.onInput);
    document.removeEventListener("keydown", this.onKeydown, true);
    document.removeEventListener("focusout", this.onFocusout);
  },

  input() {
    return document.getElementById(this.inputId);
  },

  schedule(input) {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.search(input), DEBOUNCE_MS);
  },

  async search(input) {
    const { term } = currentTerm(input.value, input.selectionStart ?? input.value.length, this.mode);
    if (term.length < MIN_TERM || term.includes("@") && term.endsWith(">")) return this.close();

    const request = ++this.request;

    try {
      const response = await fetch(`${SEARCH_PATH}?q=${encodeURIComponent(term)}`, {
        credentials: "same-origin",
        headers: { "x-requested-with": "XMLHttpRequest" },
      });
      if (!response.ok) return this.close();

      const { contacts } = await response.json();
      // An answer to an older term arriving late is dropped.
      if (request === this.request) this.show(contacts || []);
    } catch (_error) {
      this.close();
    }
  },

  show(contacts) {
    this.contacts = contacts;
    this.active = -1;
    this.list.replaceChildren(...contacts.map((contact, index) => this.option(contact, index)));
    this.list.hidden = contacts.length === 0;
    this.setExpanded(contacts.length > 0);
    this.announce(contacts.length);
  },

  option(contact, index) {
    const item = document.createElement("li");
    item.id = `${this.listId}-${index}`;
    item.setAttribute("role", "option");
    item.setAttribute("aria-selected", "false");
    item.className = "cursor-pointer px-3 py-2 hover:bg-turquoise-50 aria-selected:bg-turquoise-50";

    const name = document.createElement("span");
    name.className = "block font-medium text-tymeslot-800";
    name.textContent = contact.name || contact.email;
    item.append(name);

    if (contact.name) {
      const email = document.createElement("span");
      email.className = "block text-token-xs text-tymeslot-500";
      email.textContent = contact.email;
      item.append(email);
    }

    // Before the field's blur, so the choice is not lost to the list closing.
    item.addEventListener("mousedown", (e) => {
      e.preventDefault();
      this.pick(contact);
    });

    return item;
  },

  keydown(e) {
    if (this.list.hidden) return;

    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        this.highlight((this.active + 1) % this.contacts.length);
        break;
      case "ArrowUp":
        e.preventDefault();
        this.highlight((this.active - 1 + this.contacts.length) % this.contacts.length);
        break;
      case "Enter":
        if (this.active >= 0) {
          e.preventDefault();
          e.stopPropagation();
          this.pick(this.contacts[this.active]);
        }
        break;
      case "Escape":
        e.preventDefault();
        e.stopPropagation();
        this.close();
        break;
      default:
    }
  },

  highlight(index) {
    this.active = index;
    [...this.list.children].forEach((item, i) => item.setAttribute("aria-selected", String(i === index)));
    const item = this.list.children[index];
    item?.scrollIntoView?.({ block: "nearest" });
    this.input()?.setAttribute("aria-activedescendant", item ? item.id : "");
  },

  pick(contact) {
    const input = this.input();
    if (!input) return;

    if (this.mode === "append") {
      const { start, end } = currentTerm(input.value, input.selectionStart ?? input.value.length, "append");
      const before = input.value.slice(0, start).replace(/\s*$/, start > 0 ? " " : "");
      const after = input.value.slice(end).replace(/^[,;]?\s*/, "");
      input.value = `${before}${formatContact(contact)}, ${after}`;
      const caret = input.value.length - after.length;
      input.setSelectionRange?.(caret, caret);
    } else {
      input.value = contact.email;
    }

    this.close();
    notify(input);

    const nameInput = this.el.dataset.nameInput && document.getElementById(this.el.dataset.nameInput);
    if (nameInput && contact.name && nameInput.value.trim() === "") {
      nameInput.value = contact.name;
      notify(nameInput);
    }

    if (this.el.dataset.submit !== undefined && input.form) {
      input.form.requestSubmit();
    } else {
      input.focus();
    }
  },

  close() {
    this.contacts = [];
    this.active = -1;
    this.list.hidden = true;
    this.list.replaceChildren();
    this.setExpanded(false);
  },

  setExpanded(expanded) {
    const input = this.input();
    if (!input) return;

    input.setAttribute("role", "combobox");
    input.setAttribute("aria-autocomplete", "list");
    input.setAttribute("aria-controls", this.listId);
    input.setAttribute("aria-expanded", String(expanded));
    if (!expanded) input.removeAttribute("aria-activedescendant");
  },

  announce(count) {
    this.status.textContent = count === 0 ? "" : this.el.dataset.announce || "";
  },
};

// Tells the field's LiveView binding about a value set from here: an input
// event for a `phx-change` form, and a focusout for a `phx-blur` field,
// which is the event LiveView binds an element's `phx-blur` to.
export function notify(input) {
  input.dispatchEvent(new Event("input", { bubbles: true }));

  if (input.hasAttribute("phx-blur")) {
    input.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));
  }
}
