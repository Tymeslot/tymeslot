/**
 * Tests for the live-region text of the calendar's move mode
 * (calendar/announce.js). All words come from the server's strings map.
 */
import { expect, test } from "vitest";
import { cancelledText, movingText, rangeText, savingText } from "../../calendar/announce.js";
import { MINUTES_PER_DAY, dayNumber } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  range_on_day: "%{date}, %{start} to %{finish}",
  moving: "Moving %{title}, %{when}. Arrow keys move it.",
  move_cancelled: "Move cancelled. %{title} stays at %{when}.",
  move_saving: "Saving %{title} at %{when}.",
};
const thu = dayNumber("2026-10-15") * MINUTES_PER_DAY;
const range = { startMin: thu + 660, endMin: thu + 720 };

test("a range reads as its day and times", () => {
  expect(rangeText(range, strings, "24h")).toBe("Thu 15 Oct, 11:00 to 12:00");
  expect(rangeText({ startMin: thu + 1380, endMin: thu + 1440 }, strings, "12h")).toBe("Thu 15 Oct, 11:00 PM to 12:00 AM");
});

test("entering, cancelling and saving the move name the event and its time", () => {
  expect(movingText("Review", range, strings, "24h")).toBe("Moving Review, Thu 15 Oct, 11:00 to 12:00. Arrow keys move it.");
  expect(cancelledText("Review", range, strings, "24h")).toBe("Move cancelled. Review stays at Thu 15 Oct, 11:00 to 12:00.");
  expect(savingText("Review", range, strings, "24h")).toBe("Saving Review at Thu 15 Oct, 11:00 to 12:00.");
});

test("a missing title reads as empty, never as undefined", () => {
  for (const text of [movingText(undefined, range, strings, "24h"), cancelledText(null, range, strings, "24h"), savingText(undefined, range, strings, "24h")]) {
    expect(text).not.toContain("undefined");
    expect(text).not.toContain("null");
  }
  expect(savingText(undefined, range, strings, "24h")).toBe("Saving  at Thu 15 Oct, 11:00 to 12:00.");
});
