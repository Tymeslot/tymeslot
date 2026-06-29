import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { installAnalytics, installEventBridge, installClickTracking, AnalyticsView, HeroDemo } from "../analytics";

describe("installAnalytics", () => {
  beforeEach(() => { delete window.analytics; delete window.umami; });
  afterEach(() => { delete window.analytics; delete window.umami; });

  test("forwards name and props to umami when present", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();
    window.analytics.track("onboarding_step_completed", { step: "profile" });
    expect(window.umami.track).toHaveBeenCalledWith("onboarding_step_completed", { step: "profile" });
  });

  test("defaults props to an empty object", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();
    window.analytics.track("x");
    expect(window.umami.track).toHaveBeenCalledWith("x", {});
  });

  test("is a safe no-op when umami is absent", () => {
    installAnalytics();
    expect(() => window.analytics.track("x")).not.toThrow();
  });
});

describe("installClickTracking", () => {
  let el;

  afterEach(() => {
    if (el && el.parentNode) el.parentNode.removeChild(el);
    el = null;
  });

  test("calls analytics.track with name and parsed props on click", () => {
    const calls = [];
    const target = { umami: { track: (e, p) => calls.push([e, p]) } };
    installAnalytics(target);
    installClickTracking(target, document);

    el = document.createElement("a");
    el.dataset.analyticsEvent = "github_cta_clicked";
    el.dataset.analyticsProps = JSON.stringify({ source_page: "features" });
    document.body.appendChild(el);
    el.click();

    expect(calls).toHaveLength(1);
    expect(calls[0]).toEqual(["github_cta_clicked", { source_page: "features" }]);
  });

  test("is a no-op when no analytics provider is present", () => {
    const target = {};
    installAnalytics(target);
    installClickTracking(target, document);

    el = document.createElement("a");
    el.dataset.analyticsEvent = "github_cta_clicked";
    document.body.appendChild(el);

    expect(() => el.click()).not.toThrow();
  });
});

describe("AnalyticsView", () => {
  beforeEach(() => { delete window.analytics; delete window.umami; });
  afterEach(() => { delete window.analytics; delete window.umami; });

  test("fires the event and parsed props on mount", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();

    const el = document.createElement("div");
    el.dataset.analyticsEvent = "booking_page_viewed";
    el.dataset.analyticsProps = JSON.stringify({ tier: "free" });

    AnalyticsView.mounted.call({ el });

    expect(window.umami.track).toHaveBeenCalledWith("booking_page_viewed", { tier: "free" });
  });

  test("does nothing without an event name", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();

    const el = document.createElement("div");
    AnalyticsView.mounted.call({ el });

    expect(window.umami.track).not.toHaveBeenCalled();
  });

  test("is a safe no-op when no provider is present", () => {
    const el = document.createElement("div");
    el.dataset.analyticsEvent = "booking_page_viewed";

    expect(() => AnalyticsView.mounted.call({ el })).not.toThrow();
  });
});

describe("HeroDemo", () => {
  beforeEach(() => { delete window.analytics; delete window.umami; });
  afterEach(() => { delete window.analytics; delete window.umami; });

  // Mirrors the LiveView call convention: mounted() reaches `this.revealCta`,
  // so the context must delegate to the hook object.
  function mountHook(el) {
    const ctx = Object.assign(Object.create(HeroDemo), { el });
    ctx.mounted();
    return ctx;
  }

  function visibleVideo(props = { variant: "video", surface: "homepage_hero" }) {
    const el = document.createElement("video");
    el.dataset.analyticsEvent = "hero_demo_viewed";
    el.dataset.analyticsProps = JSON.stringify(props);
    el.dataset.ctaTarget = "hero-demo-cta";
    Object.defineProperty(el, "offsetParent", { value: document.body, configurable: true });
    return el;
  }

  function hiddenCta() {
    const cta = document.createElement("div");
    cta.id = "hero-demo-cta";
    cta.style.opacity = "0";
    cta.style.pointerEvents = "none";
    document.body.appendChild(cta);
    return cta;
  }

  test("fires hero_demo_viewed when the element is visible", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();

    const el = document.createElement("img");
    el.dataset.analyticsEvent = "hero_demo_viewed";
    el.dataset.analyticsProps = JSON.stringify({ variant: "poster", surface: "homepage_hero" });
    Object.defineProperty(el, "offsetParent", { value: document.body, configurable: true });

    mountHook(el);

    expect(window.umami.track).toHaveBeenCalledWith("hero_demo_viewed", {
      variant: "poster",
      surface: "homepage_hero",
    });
  });

  test("does not fire when the element is hidden (offsetParent is null)", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();

    const el = document.createElement("img");
    el.dataset.analyticsEvent = "hero_demo_viewed";
    el.dataset.analyticsProps = JSON.stringify({ variant: "poster", surface: "homepage_hero" });
    Object.defineProperty(el, "offsetParent", { value: null, configurable: true });

    mountHook(el);

    expect(window.umami.track).not.toHaveBeenCalled();
  });

  test("on the video's end, reveals the CTA and reports completion exactly once", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();
    const cta = hiddenCta();
    const el = visibleVideo();
    el.play = vi.fn(() => Promise.resolve());

    mountHook(el);
    el.dispatchEvent(new Event("ended"));
    // A stray second `ended` must not double-report (listener is once-only).
    el.dispatchEvent(new Event("ended"));

    expect(cta.style.opacity).toBe("1");
    expect(cta.style.pointerEvents).toBe("auto");
    const completed = window.umami.track.mock.calls.filter(([name]) => name === "hero_demo_completed");
    expect(completed).toEqual([["hero_demo_completed", { surface: "homepage_hero" }]]);

    cta.remove();
  });

  test("reveals the CTA immediately when autoplay is blocked, without reporting completion", async () => {
    window.umami = { track: vi.fn() };
    installAnalytics();
    const cta = hiddenCta();
    const el = visibleVideo();
    el.play = vi.fn(() => Promise.reject(new Error("autoplay blocked")));

    mountHook(el);
    await new Promise((resolve) => setTimeout(resolve, 0)); // let the rejected play() settle

    expect(cta.style.opacity).toBe("1");
    expect(cta.style.pointerEvents).toBe("auto");
    expect(window.umami.track).not.toHaveBeenCalledWith("hero_demo_completed", expect.anything());

    cta.remove();
  });

  test("is a safe no-op when no provider is present", () => {
    const el = document.createElement("img");
    el.dataset.analyticsEvent = "hero_demo_viewed";
    Object.defineProperty(el, "offsetParent", { value: document.body, configurable: true });

    expect(() => mountHook(el)).not.toThrow();
  });
});

describe("installEventBridge", () => {
  beforeEach(() => { delete window.analytics; delete window.umami; });
  afterEach(() => { delete window.analytics; delete window.umami; });

  test("forwards a phx:ts:analytics window event to analytics.track", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();
    installEventBridge();
    window.dispatchEvent(new CustomEvent("phx:ts:analytics", {
      detail: { name: "onboarding_step_completed", props: { step: "welcome" } },
    }));
    expect(window.umami.track).toHaveBeenCalledWith("onboarding_step_completed", { step: "welcome" });
  });

  test("tolerates a missing props payload", () => {
    window.umami = { track: vi.fn() };
    installAnalytics();
    installEventBridge();
    window.dispatchEvent(new CustomEvent("phx:ts:analytics", { detail: { name: "x" } }));
    expect(window.umami.track).toHaveBeenCalledWith("x", {});
  });
});
