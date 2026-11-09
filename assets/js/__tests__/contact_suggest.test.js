import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { ContactSuggest, currentTerm, formatContact } from "../hooks/contact_suggest";

describe("currentTerm", () => {
  it("is the whole value when replacing", () => {
    expect(currentTerm("  ada ", 3, "replace")).toEqual({ term: "ada", start: 0, end: 6 });
  });

  it("is the address under the cursor when appending", () => {
    const value = "grace@example.com, ad, bob@example.com";
    expect(currentTerm(value, 21, "append")).toEqual({ term: "ad", start: 18, end: 21 });
  });

  it("reads past a line break as a separator", () => {
    expect(currentTerm("grace@example.com\nada", 21, "append").term).toBe("ada");
  });
});

describe("formatContact", () => {
  it("names the contact before the address, without characters that would split it", () => {
    expect(formatContact({ name: 'Hopper, "Grace"', email: "grace@example.com" })).toBe(
      "Hopper Grace <grace@example.com>"
    );
    expect(formatContact({ name: null, email: "ops@example.com" })).toBe("ops@example.com");
  });
});

describe("ContactSuggest hook", () => {
  let hook;
  let input;

  function mount(dataset) {
    document.body.innerHTML = `
      <form id="f"><input id="guest" type="email" /></form>
      <div id="anchor"></div>`;
    input = document.getElementById("guest");
    const el = document.getElementById("anchor");
    Object.assign(el.dataset, { input: "guest", announce: "Contacts suggested.", ...dataset });
    hook = Object.create(ContactSuggest);
    hook.el = el;
    hook.mounted();
    return el;
  }

  beforeEach(() => {
    vi.useFakeTimers();
    global.fetch = vi.fn(async () => ({
      ok: true,
      json: async () => ({
        contacts: [
          { name: "Ada Lovelace", email: "ada@example.com" },
          { name: null, email: "adm@example.com" },
        ],
      }),
    }));
  });

  afterEach(() => {
    hook?.destroyed();
    vi.useRealTimers();
  });

  async function type(value) {
    input.value = value;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    await vi.advanceTimersByTimeAsync(300);
  }

  it("asks for the term once typing pauses and lists what comes back", async () => {
    const el = mount({});
    await type("ad");

    expect(fetch).toHaveBeenCalledWith("/dashboard/contacts/search?q=ad", expect.anything());
    const options = el.querySelectorAll("[role=option]");
    expect(options).toHaveLength(2);
    expect(options[0].textContent).toContain("Ada Lovelace");
    expect(input.getAttribute("aria-expanded")).toBe("true");
    expect(el.querySelector("[role=status]").textContent).toBe("Contacts suggested.");
  });

  it("does not ask for a single character", async () => {
    mount({});
    await type("a");
    expect(fetch).not.toHaveBeenCalled();
  });

  it("chooses with the arrow keys and Enter, and submits an Add form", async () => {
    const el = mount({ submit: "" });
    const submitted = vi.fn((e) => e.preventDefault());
    input.form.addEventListener("submit", submitted);
    input.form.requestSubmit = () => input.form.dispatchEvent(new Event("submit", { cancelable: true }));

    await type("ad");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    expect(input.getAttribute("aria-activedescendant")).toBe("guest-contact-suggestions-0");

    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(input.value).toBe("ada@example.com");
    expect(submitted).toHaveBeenCalled();
    expect(el.querySelector("[role=listbox]").hidden).toBe(true);
  });

  it("fills in the name with the address in a field that takes both", async () => {
    mount({ named: "" });
    await type("ad");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    expect(input.value).toBe("Ada Lovelace <ada@example.com>");
  });

  it("closes on Escape without choosing", async () => {
    const el = mount({});
    await type("ad");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));

    expect(el.querySelector("[role=listbox]").hidden).toBe(true);
    expect(input.value).toBe("ad");
  });
});
