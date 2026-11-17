/**
 * Tests for quick-create parsing (calendar/parse.js). Today is Sunday 18
 * October 2026; the draft started from a click on Tuesday 20 October at
 * 10:00, 30 minutes long, on the Work calendar, so a field that the text
 * did not change shows the slot's value.
 */
import { describe, expect, test } from "vitest";
import { parseQuick } from "../../calendar/parse.js";

const today = "2026-10-18";
const calendars = [
  { key: "7:work", name: "Work" },
  { key: "7:personal", name: "Personal" },
  { key: "9:team", name: "Team planning" },
  { key: "9:cafe", name: "Café club" },
];
const base = { day: "2026-10-20", startMin: 600, length: 30, allDay: false, days: 1, calendar: "7:work" };
const parse = (text, over = {}) => parseQuick(text, { ...base, ...over }, { today, calendars });

// [typed, what the result must contain]
const corpus = [
  // Nothing but a title: the slot stays as it was.
  ["Dentist", { title: "Dentist", start: "2026-10-20T10:00", end: "2026-10-20T10:30", allDay: false }],
  ["", { title: "", start: "2026-10-20T10:00", end: "2026-10-20T10:30" }],
  ["dentist", { title: "Dentist" }],
  ["iPhone repair", { title: "iPhone repair" }],
  ["Room 12 review", { title: "Room 12 review", start: "2026-10-20T10:00" }],
  ["Table for 2", { title: "Table for 2", start: "2026-10-20T10:00" }],
  ["10-12 workshop", { title: "10-12 workshop", start: "2026-10-20T10:00" }],

  // Relative days.
  ["lunch today", { title: "Lunch", start: "2026-10-18T10:00" }],
  ["lunch tomorrow 13:00", { title: "Lunch", start: "2026-10-19T13:00", end: "2026-10-19T13:30" }],
  ["call tmrw 9am", { title: "Call", start: "2026-10-19T09:00" }],
  ["drinks tonight 19:30", { title: "Drinks", start: "2026-10-18T19:30" }],

  // Weekdays: the next one on or after today; "next" only skips today.
  ["standup fri 9:15", { title: "Standup", start: "2026-10-23T09:15" }],
  ["standup on friday", { title: "Standup", start: "2026-10-23T10:00" }],
  ["review next friday", { title: "Review", start: "2026-10-23T10:00" }],
  ["review sun", { title: "Review", start: "2026-10-18T10:00" }],
  ["review next sunday", { title: "Review", start: "2026-10-25T10:00" }],
  ["Sunday roast prep", { title: "Roast prep", start: "2026-10-18T10:00", found: { date: true } }],
  ['"Sunday roast" prep', { title: "Sunday roast prep", start: "2026-10-20T10:00", found: { date: false } }],
  ["Sat nav repair", { title: "Sat nav repair", start: "2026-10-20T10:00", found: { date: false } }],
  ["Sun lounge order", { title: "Sun lounge order", found: { date: false } }],
  ["lunch sat", { title: "Lunch", start: "2026-10-24T10:00" }],
  ["sat 3pm lunch", { title: "Lunch", start: "2026-10-24T15:00" }],
  ["Mondays are hard", { title: "Mondays are hard", found: { date: false } }],

  // Day spans.
  ["x sat sun", { title: "X", allDay: true, start: "2026-10-24", end: "2026-10-26" }],
  ["retreat fri-sun", { title: "Retreat", allDay: true, start: "2026-10-23", end: "2026-10-26" }],
  ["conference 20-22 oct", { title: "Conference", allDay: true, start: "2026-10-20", end: "2026-10-23" }],
  ["trip 30 dec to 2 jan", { title: "Trip", allDay: true, start: "2026-12-30", end: "2027-01-03" }],
  ["dentist mon, physio tue", { title: "Dentist, physio tue", start: "2026-10-19T10:00" }],

  // Named dates, day first or month first, with or without a year.
  ["dinner 17 oct", { title: "Dinner", start: "2026-10-17T10:00" }],
  ["dinner on 24 october at 19:00 with Sam", { title: "Dinner with Sam", start: "2026-10-24T19:00" }],
  ["dinner oct 24th", { title: "Dinner", start: "2026-10-24T10:00" }],
  ["dinner 24th oct", { title: "Dinner", start: "2026-10-24T10:00" }],
  ["launch 20 oct 2027", { title: "Launch", start: "2027-10-20T10:00" }],
  ["launch march 3, 2027", { title: "Launch", start: "2027-03-03T10:00" }],
  ["review 3 may changes", { title: "Review changes", start: "2027-05-03T10:00" }],

  // Numeric dates: day first, never month first.
  ["party 17/10", { title: "Party", start: "2026-10-17T10:00" }],
  ["party 5/11", { title: "Party", start: "2026-11-05T10:00" }],
  ["party 17/10/2026", { title: "Party", start: "2026-10-17T10:00" }],
  ["party 17/10/27", { title: "Party", start: "2027-10-17T10:00" }],
  ["party 17.10.", { title: "Party", start: "2026-10-17T10:00" }],
  ["party 17.10.2027", { title: "Party", start: "2027-10-17T10:00" }],
  ["party 2026-10-20 18:00", { title: "Party", start: "2026-10-20T18:00" }],
  ["10/13 sync", { title: "10/13 sync", found: { date: false } }],

  // Dates that do not exist are not read.
  ["x 31 feb", { title: "X 31 feb", start: "2026-10-20T10:00", found: { date: false } }],
  ["x 31/4", { title: "X 31/4", found: { date: false } }],
  ["x 29/2/2028", { start: "2028-02-29T10:00" }],
  ["x 2026-13-01", { title: "X 2026-13-01", found: { date: false } }],

  // Past dates: up to 30 days back stay this year, older ones roll on.
  ["retro 10 oct", { start: "2026-10-10T10:00" }],
  ["retro 18 sep", { start: "2026-09-18T10:00" }],
  ["retro 17 sep", { start: "2027-09-17T10:00" }],
  ["new year 1 jan", { title: "New year", start: "2027-01-01T10:00" }],
  ["retro 1 sep 2026", { start: "2026-09-01T10:00" }],

  // Times.
  ["call 14:30", { start: "2026-10-20T14:30", end: "2026-10-20T15:00" }],
  ["call 14.30", { start: "2026-10-20T14:30" }],
  ["call 2pm", { start: "2026-10-20T14:00" }],
  ["call 2:30 p.m.", { start: "2026-10-20T14:30" }],
  ["call 12am", { start: "2026-10-20T00:00" }],
  ["call 12pm", { start: "2026-10-20T12:00" }],
  ["lunch at noon", { title: "Lunch", start: "2026-10-20T12:00" }],
  ["lunch noon", { title: "Lunch", start: "2026-10-20T12:00" }],
  ["release midnight", { title: "Release", start: "2026-10-20T00:00" }],
  ["call at 2", { title: "Call", start: "2026-10-20T14:00" }],
  ["lunch at 1", { title: "Lunch", start: "2026-10-20T13:00" }],
  ["call 1.30", { start: "2026-10-20T13:30" }],
  ["pick up kids 3:15", { title: "Pick up kids", start: "2026-10-20T15:15" }],
  ["gym at 6", { title: "Gym", start: "2026-10-20T18:00" }],
  ["call 03:15", { start: "2026-10-20T03:15" }],
  ["call 06:00", { start: "2026-10-20T06:00" }],
  ["call 3am", { start: "2026-10-20T03:00" }],
  ["call 7:00", { start: "2026-10-20T07:00" }],
  ["call 12:00", { start: "2026-10-20T12:00" }],
  ["class from 2 to 4", { start: "2026-10-20T14:00", end: "2026-10-20T16:00" }],
  ["class 1-2pm", { start: "2026-10-20T13:00", end: "2026-10-20T14:00" }],
  ["Pay £12.50 to Tom", { title: "Pay £12.50 to Tom", start: "2026-10-20T10:00", found: { time: false } }],
  ["Pay €20.00 deposit", { title: "Pay €20.00 deposit", start: "2026-10-20T10:00", found: { time: false } }],
  ["Version 1.10.2 release", { title: "Version 1.10.2 release", start: "2026-10-20T10:00", found: { time: false } }],
  ["Team sync every monday 10:00", { title: "Team sync every monday", start: "2026-10-20T10:00" }],
  ["Standup each fri", { title: "Standup each fri", start: "2026-10-20T10:00", found: { date: false } }],
  ["Mon-Fri conference", { title: "Conference", allDay: true, start: "2026-10-19", end: "2026-10-24" }],
  ["Sat-sun hike", { title: "Hike", allDay: true, start: "2026-10-24", end: "2026-10-26" }],
  ["call 13pm", { title: "Call 13pm", start: "2026-10-20T10:00", found: { time: false } }],
  ["call 25:00", { title: "Call 25:00", found: { time: false } }],

  // Ranges, including overnight.
  ["workshop 14:00-15:30", { start: "2026-10-20T14:00", end: "2026-10-20T15:30" }],
  ["workshop 14:00 – 15:30", { start: "2026-10-20T14:00", end: "2026-10-20T15:30" }],
  ["workshop 14:00—15:30", { start: "2026-10-20T14:00", end: "2026-10-20T15:30" }],
  ["workshop 14:00 to 15:30", { start: "2026-10-20T14:00", end: "2026-10-20T15:30" }],
  ["workshop from 2 until 4pm", { start: "2026-10-20T14:00", end: "2026-10-20T16:00" }],
  ["class 2-3pm", { start: "2026-10-20T14:00", end: "2026-10-20T15:00" }],
  ["class 11-1pm", { start: "2026-10-20T11:00", end: "2026-10-20T13:00" }],
  ["class 10-12pm", { start: "2026-10-20T10:00", end: "2026-10-20T12:00" }],
  ["class 9am-5", { start: "2026-10-20T09:00", end: "2026-10-20T17:00" }],
  ["class 10:00-2:00", { start: "2026-10-20T10:00", end: "2026-10-20T14:00" }],
  ["class 10am to noon", { start: "2026-10-20T10:00", end: "2026-10-20T12:00" }],
  ["shift 9-17", { title: "Shift", start: "2026-10-20T09:00", end: "2026-10-20T17:00" }],
  ["shift from 9 to 5", { title: "Shift", start: "2026-10-20T09:00", end: "2026-10-20T17:00" }],
  ["party 22:00-02:00", { start: "2026-10-20T22:00", end: "2026-10-21T02:00" }],
  ["party 23:00-1:00", { start: "2026-10-20T23:00", end: "2026-10-21T01:00" }],
  ["night 10:00-02:00", { start: "2026-10-20T10:00", end: "2026-10-21T02:00" }],
  ["gig 11pm-midnight", { start: "2026-10-20T23:00", end: "2026-10-21T00:00" }],
  ["gig 11pm-1am", { start: "2026-10-20T23:00", end: "2026-10-21T01:00" }],
  ["weekend sat 10:00 - sun 12:00", { title: "Weekend - sun 12:00", start: "2026-10-24T10:00" }],
  ["retreat fri-sun 9:00-17:00", { allDay: false, start: "2026-10-23T09:00", end: "2026-10-25T17:00" }],
  ["brunch sat sun 11:00", { title: "Brunch", allDay: false, start: "2026-10-24T11:00", end: "2026-10-25T11:30" }],

  // Durations.
  ["call for 45m", { start: "2026-10-20T10:00", end: "2026-10-20T10:45" }],
  ["call 15:00 for 45 minutes", { start: "2026-10-20T15:00", end: "2026-10-20T15:45" }],
  ["30-minute check-in at 9:00", { title: "Check-in", start: "2026-10-20T09:00", end: "2026-10-20T09:30" }],
  ["deep work 1,5h", { title: "Deep work", end: "2026-10-20T11:30" }],
  ["deep work 1.5 hours", { end: "2026-10-20T11:30" }],
  ["deep work 1h30", { end: "2026-10-20T11:30" }],
  ["deep work 2 hrs", { end: "2026-10-20T12:00" }],
  ["chat for half an hour", { title: "Chat", end: "2026-10-20T10:30" }],
  ["chat for an hour", { title: "Chat", end: "2026-10-20T11:00" }],
  ["late call 23:30 for 1h", { start: "2026-10-20T23:30", end: "2026-10-21T00:30" }],
  ["call 14:00-15:00 for 2h", { end: "2026-10-20T15:00" }],

  // All day.
  ["holiday all day", { title: "Holiday", allDay: true, start: "2026-10-20", end: "2026-10-21" }],
  ["holiday all-day fri", { title: "Holiday", allDay: true, start: "2026-10-23", end: "2026-10-24" }],
  ["holiday", { allDay: true, start: "2026-10-20", end: "2026-10-21" }, { allDay: true }],
  ["holiday 9:00", { allDay: false, start: "2026-10-20T09:00" }, { allDay: true }],
  ["holiday all day 14:00", { allDay: false, start: "2026-10-20T14:00" }],

  // Calendars, guests and places.
  ["gym /personal", { title: "Gym", calendar: "7:personal", found: { calendar: true } }],
  ["gym /PER", { calendar: "7:personal" }],
  ["sync /planning", { title: "Sync", calendar: "9:team" }],
  ["coffee /cafe", { title: "Coffee", calendar: "9:cafe" }],
  ["gym /nowhere", { title: "Gym /nowhere", calendar: "7:work", found: { calendar: false } }],
  ["Q3 report 17/10 /work", { title: "Q3 report", calendar: "7:work", start: "2026-10-17T10:00" }],
  ["1:1 @anna@example.com", { title: "1:1", guests: ["anna@example.com"] }],
  ["1:1 @anna", { title: "1:1 @anna", guests: [], found: { guests: false } }],
  ["kick-off @a@x.io @b@y.org @A@x.io", { title: "Kick-off", guests: ["a@x.io", "b@y.org"] }],
  ["mail anna@example.com", { title: "Mail anna@example.com", guests: [] }],
  ["lunch with @sam@example.com, tomorrow", { title: "Lunch", guests: ["sam@example.com"], start: "2026-10-19T10:00" }],
  ["coffee ;Nero", { title: "Coffee", location: "Nero" }],
  ["coffee ;Café Nero 3pm", { title: "Coffee", location: "Café Nero", start: "2026-10-20T15:00" }],
  ["coffee ;Café Nero tomorrow at 9:30 /personal", { location: "Café Nero", start: "2026-10-19T09:30", calendar: "7:personal" }],
  ["drinks ;Monday Club", { title: "Drinks", location: "Monday Club", start: "2026-10-20T10:00" }],
  ["viewing ;Flat 3 May Road", { title: "Viewing", location: "Flat 3 May Road", start: "2026-10-20T10:00" }],
  ['drinks ;"The Sun" 18:00', { location: "The Sun", start: "2026-10-20T18:00" }],
  ["coffee ;Nero @sam@example.com", { location: "Nero", guests: ["sam@example.com"] }],
  [
    "Board meeting tomorrow 14:00-15:30 /team ;Room 4 @cfo@example.com",
    { title: "Board meeting", start: "2026-10-19T14:00", end: "2026-10-19T15:30", calendar: "9:team", location: "Room 4", guests: ["cfo@example.com"] },
  ],

  // Title cleanup.
  ["lunch at", { title: "Lunch" }],
  ["at 13:00 lunch", { title: "Lunch", start: "2026-10-20T13:00" }],
  ["lunch, tomorrow", { title: "Lunch" }],
  ["  lunch   tomorrow  ", { title: "Lunch" }],
];

describe("the corpus", () => {
  test.each(corpus)("%s", (text, expected, over) => {
    const result = parse(text, over);
    const { found, ...rest } = expected;
    expect(result).toMatchObject(rest);
    if (found) expect(result.found).toMatchObject(found);
  });
});

test("the corpus covers at least 60 cases", () => {
  expect(corpus.length).toBeGreaterThanOrEqual(60);
});

test("found says what the text supplied", () => {
  expect(parse("Board meeting tomorrow 14:00 /team ;Room 4 @cfo@example.com").found).toEqual({
    date: true,
    time: true,
    calendar: true,
    location: true,
    guests: true,
  });
  expect(parse("Dentist").found).toEqual({ date: false, time: false, calendar: false, location: false, guests: false });
});

test("an all-day draft spanning days keeps its length when the text names no day", () => {
  expect(parse("Offsite", { allDay: true, days: 3 })).toMatchObject({ allDay: true, start: "2026-10-20", end: "2026-10-23" });
});

test("today is injected, never read from the clock", () => {
  const result = parseQuick("review tomorrow", base, { today: "2030-01-31", calendars });
  expect(result.start).toBe("2030-02-01T10:00");
});

test("with no calendars a /word stays in the title and the base calendar is kept", () => {
  const result = parseQuick("gym /personal", base, { today });
  expect(result).toMatchObject({ title: "Gym /personal", calendar: "7:work" });
});

test("user text is returned as typed, never interpreted as markup", () => {
  expect(parse('<img src=x onerror="alert(1)"> 14:00').title).toBe("<img src=x onerror=alert(1)>");
});
