import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import {
  installAnalytics,
  installEventBridge,
  installClickTracking,
  AnalyticsView,
  scrubAnalyticsUrl,
  scrubAnalyticsPayload,
  BEFORE_SEND_GLOBAL,
} from "../analytics";

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

  test("buffers events fired before the provider arrives and flushes them on ready", () => {
    const listeners = {};
    const target = { addEventListener: (name, fn) => { listeners[name] = fn; } };
    installAnalytics(target);

    target.analytics.track("booking_page_viewed", { tier: "free" });
    target.analytics.track("signup_started", { source_page: "marketing" });

    const calls = [];
    target.umami = { track: (e, p) => calls.push([e, p]) };
    listeners["tymeslot:analytics-ready"]();

    expect(calls).toEqual([
      ["booking_page_viewed", { tier: "free" }],
      ["signup_started", { source_page: "marketing" }],
    ]);
  });

  test("flushes buffered events ahead of the first event tracked after the provider arrives", () => {
    const target = { addEventListener: () => {} };
    installAnalytics(target);
    target.analytics.track("early");

    const calls = [];
    target.umami = { track: (e) => calls.push(e) };
    target.analytics.track("late");

    expect(calls).toEqual(["early", "late"]);
  });

  test("bounds the buffer when no provider ever arrives", () => {
    const target = { addEventListener: () => {} };
    installAnalytics(target);
    for (let i = 0; i < 120; i++) target.analytics.track(`e${i}`);

    const calls = [];
    target.umami = { track: (e) => calls.push(e) };
    target.analytics.track("last");

    expect(calls).toHaveLength(51);
    expect(calls[0]).toBe("e0");
    expect(calls[50]).toBe("last");
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

describe("scrubAnalyticsUrl", () => {
  test("removes the meeting uid from cancel and reschedule links", () => {
    const uid = "8f14e45f-ceea-4e67-a7a5-6b1e2c3d4f50";
    expect(scrubAnalyticsUrl(`https://tymeslot.app/luka/meeting/${uid}/cancel`)).toBe(
      "https://tymeslot.app/luka/meeting/:uid/cancel",
    );
    expect(scrubAnalyticsUrl(`/luka/meeting/${uid}/reschedule`)).toBe("/luka/meeting/:uid/reschedule");
  });

  test("drops identifying query parameters but keeps campaign tags", () => {
    expect(
      scrubAnalyticsUrl(
        "https://tymeslot.app/luka?reschedule_meeting_uid=abc&email=a%40b.c&name=Ann&utm_source=newsletter#slot",
      ),
    ).toBe("https://tymeslot.app/luka?utm_source=newsletter");
  });

  test("leaves ordinary addresses alone", () => {
    expect(scrubAnalyticsUrl("https://tymeslot.app/pricing")).toBe("https://tymeslot.app/pricing");
    expect(scrubAnalyticsUrl("/luka/30min")).toBe("/luka/30min");
    expect(scrubAnalyticsUrl("")).toBe("");
    expect(scrubAnalyticsUrl(undefined)).toBe(undefined);
  });
});

describe("scrubAnalyticsPayload", () => {
  test("scrubs both the page address and the referrer", () => {
    const payload = {
      website: "abc",
      title: "Cancel meeting",
      url: "https://tymeslot.app/luka/meeting/secret-uid/cancel",
      referrer: "/luka?reschedule_meeting_uid=secret-uid",
    };

    expect(scrubAnalyticsPayload("event", payload)).toEqual({
      website: "abc",
      title: "Cancel meeting",
      url: "https://tymeslot.app/luka/meeting/:uid/cancel",
      referrer: "/luka",
    });
  });

  test("installAnalytics publishes the scrubber under the name the loader hands to Umami", () => {
    const target = { addEventListener: () => {} };
    installAnalytics(target);
    expect(target[BEFORE_SEND_GLOBAL]).toBe(scrubAnalyticsPayload);
    expect(BEFORE_SEND_GLOBAL).toBe("tymeslotAnalyticsBeforeSend");
  });
});
