/**
 * The dashboard bundle registers the calendar's hooks and none of the old
 * calendar grid's (CalendarDrag, CalendarResize, CalendarCreate,
 * CalendarMobile), which no page renders any more.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, test } from "vitest";

const bundle = readFileSync(resolve(__dirname, "../bundles/dashboard.js"), "utf8");

describe("the dashboard bundle", () => {
  test("registers the calendar canvas and its reminders", () => {
    expect(bundle).toMatch(/CalendarCanvas: lazyHook\(/);
    expect(bundle).toMatch(/DesktopReminders: lazyHook\(/);
  });

  test("registers none of the old grid's hooks", () => {
    for (const name of ["CalendarDrag", "CalendarResize", "CalendarCreate", "CalendarMobile"]) {
      expect(bundle).not.toMatch(new RegExp(`\\b${name}:`));
    }
    expect(bundle).not.toMatch(/hooks\/calendar_drag/);
  });
});
