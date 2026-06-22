// Reveal a fallback element (or simply hide the image) when a marked <img>
// fails to load. Registered in the capture phase because the DOM "error"
// event does not bubble. This replaces inline onerror="" handlers, which a
// nonce-based CSP (script-src without 'unsafe-inline') blocks.
//
// Markup contract on the <img>:
//   data-img-fallback            enables the behaviour
//   data-fallback-selector="…"   optional CSS selector, queried within the
//                                image's parentElement, for the element to
//                                reveal; defaults to the image's nextElementSibling
//   data-fallback-display="…"    display value applied to the revealed element
//                                (default "flex")
export function installImageFallback() {
  document.addEventListener(
    "error",
    (event) => {
      const img = event.target;
      if (!(img instanceof HTMLImageElement) || !img.hasAttribute("data-img-fallback")) {
        return;
      }

      img.style.display = "none";

      const selector = img.dataset.fallbackSelector;
      const fallback = selector
        ? img.parentElement && img.parentElement.querySelector(selector)
        : img.nextElementSibling;

      if (fallback) {
        fallback.style.display = img.dataset.fallbackDisplay || "flex";
      }
    },
    true
  );
}
