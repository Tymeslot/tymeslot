/**
 * DocsToc Hook
 *
 * Automatically builds a floating table-of-contents panel with share buttons
 * for documentation articles. Scans the rendered article for h3 headings,
 * injects anchor IDs, and appends a fixed panel to the body.
 *
 * The panel fades in once the user scrolls > 300px within the docs scroll
 * container and is only shown on xl+ screens where layout space permits.
 */

const SCROLL_CONTAINER_ID = "docs-content-container";
const TOC_PANEL_ID = "docs-toc-panel";
const SCROLL_THRESHOLD = 300;
const MIN_HEADINGS = 2;

function slugify(text) {
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

// Extract the visible label from a heading.
// Uses full textContent to handle inline elements (em, strong, code, etc.),
// then strips any leading non-letter/non-digit prefix (e.g. emoji spans).
function headingLabel(el) {
  return el.textContent.trim().replace(/^[^\p{L}\p{N}]+/u, "").trim();
}

function buildPanel(headings) {
  const url = encodeURIComponent(window.location.href);
  const title = encodeURIComponent(document.title);

  const shareLinks = [
    {
      label: "Share on LinkedIn",
      href: `https://www.linkedin.com/sharing/share-offsite/?url=${url}`,
      icon: `<path d="M20.447 20.452h-3.554v-5.569c0-1.328-.027-3.037-1.852-3.037-1.853 0-2.136 1.445-2.136 2.939v5.667H9.351V9h3.414v1.561h.046c.477-.9 1.637-1.85 3.37-1.85 3.601 0 4.267 2.37 4.267 5.455v6.286zM5.337 7.433c-1.144 0-2.063-.926-2.063-2.065 0-1.138.92-2.063 2.063-2.063 1.14 0 2.064.925 2.064 2.063 0 1.139-.925 2.065-2.064 2.065zm1.782 13.019H3.555V9h3.564v11.452zM22.225 0H1.771C.792 0 0 .774 0 1.729v20.542C0 23.227.792 24 1.771 24h20.451C23.2 24 24 23.227 24 22.271V1.729C24 .774 23.2 0 22.222 0h.003z"/>`,
      color: "text-blue-600 hover:text-blue-800"
    },
    {
      label: "Share on X",
      href: `https://twitter.com/intent/tweet?url=${url}&text=${title}`,
      icon: `<path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>`,
      color: "text-gray-800 hover:text-gray-600"
    },
    {
      label: "Share on WhatsApp",
      href: `https://wa.me/?text=${title}%20${url}`,
      icon: `<path d="M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413z"/>`,
      color: "text-green-600 hover:text-green-800"
    }
  ];

  const shareIcons = shareLinks
    .map(
      s => `
        <a
          href="${s.href}"
          target="_blank"
          rel="noopener noreferrer"
          aria-label="${s.label}"
          class="${s.color} transition-colors"
        >
          <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24" aria-hidden="true">
            ${s.icon}
          </svg>
        </a>`
    )
    .join("");

  const panel = document.createElement("div");
  panel.id = TOC_PANEL_ID;
  panel.className =
    "fixed right-6 bottom-6 z-50 bg-white rounded-2xl shadow-xl border border-gray-200 p-6 w-72 transition-opacity duration-300 opacity-0";
  panel.style.display = "block";
  panel.style.maxHeight = "75vh";
  panel.style.overflowY = "auto";

  // Static panel skeleton — all strings are developer-controlled constants or URL-encoded values.
  panel.innerHTML = `
    <div class="flex items-center gap-2 mb-3">
      <svg class="w-4 h-4 text-turquoise-600 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5"
          d="M4 6h16M4 10h16M4 14h10" />
      </svg>
      <span class="text-xs font-bold text-gray-900 uppercase tracking-wider">On this page</span>
    </div>
    <ul class="space-y-0.5 mb-4"></ul>
    <div class="pt-3 border-t border-gray-100">
      <p class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Share</p>
      <div class="flex items-center gap-3">${shareIcons}</div>
    </div>
  `;

  // Build TOC list items with DOM APIs — heading labels are raw text and must not be
  // injected as HTML since textContent preserves literal < > characters.
  const list = panel.querySelector("ul");
  headings.forEach(h => {
    const li = document.createElement("li");
    const a = document.createElement("a");
    a.href = `#${h.id}`;
    a.className = "toc-link text-xs text-gray-600 hover:text-turquoise-600 transition-colors leading-snug flex items-start gap-1.5 py-0.5";
    a.dataset.targetId = h.id;
    const dot = document.createElement("span");
    dot.className = "mt-1.5 w-1 h-1 rounded-full bg-gray-300 shrink-0";
    a.appendChild(dot);
    a.appendChild(document.createTextNode(headingLabel(h)));
    li.appendChild(a);
    list.appendChild(li);
  });

  return panel;
}

export const DocsToc = {
  mounted() {
    this.scrollContainer = document.getElementById(SCROLL_CONTAINER_ID);
    this.scrollHandler = () => this.handleScroll();
    this.scrollContainer?.addEventListener("scroll", this.scrollHandler);

    this.xlQuery = window.matchMedia("(min-width: 1280px)");
    this.xlHandler = e => (e.matches ? this.build() : this.removePanel());
    this.xlQuery.addEventListener("change", this.xlHandler);

    this.build();
  },

  updated() {
    this.removePanel();
    this.build();
    // Panel starts opacity-0; scroll handler will show it once user scrolls.
    // ScrollReset resets scrollTop to 0 on navigation, so the panel stays
    // hidden until they scroll down again.
  },

  destroyed() {
    this.removePanel();
    this.scrollContainer?.removeEventListener("scroll", this.scrollHandler);
    this.xlQuery?.removeEventListener("change", this.xlHandler);
  },

  build() {
    if (!this.xlQuery?.matches) return;
    const headings = Array.from(this.el.querySelectorAll("h3"));
    if (headings.length < MIN_HEADINGS) return;

    headings.forEach(h => {
      if (!h.id) {
        h.id = slugify(headingLabel(h));
      }
    });

    this.panel = buildPanel(headings);
    document.body.appendChild(this.panel);

    this.panel.querySelectorAll(".toc-link").forEach(link => {
      link.addEventListener("click", e => {
        e.preventDefault();
        const target = document.getElementById(link.dataset.targetId);
        if (target && this.scrollContainer) {
          const containerRect = this.scrollContainer.getBoundingClientRect();
          const targetRect = target.getBoundingClientRect();
          const offset = this.scrollContainer.scrollTop + (targetRect.top - containerRect.top) - 32;
          this.scrollContainer.scrollTo({ top: offset, behavior: "smooth" });
        }
      });
    });
  },

  handleScroll() {
    if (!this.panel) return;
    const scrolled = (this.scrollContainer?.scrollTop ?? 0) > SCROLL_THRESHOLD;
    this.panel.classList.toggle("opacity-0", !scrolled);
    this.panel.classList.toggle("opacity-100", scrolled);
  },

  removePanel() {
    const existing = document.getElementById(TOC_PANEL_ID);
    if (existing) existing.remove();
    this.panel = null;
  }
};
