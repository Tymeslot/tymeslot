# Folio: the person who is the product

## Persona

Coaches, therapists, consultants, writers and freelancers whose booking page is in effect their homepage. Visitors arrive from a profile link and want to know who this is before they book.

## Story

> People book me, not a time slot. Before they pick a date, they should know who I am, what I do, and whether we're a fit.

## Journey

`Navigators.Continuous`, one long page that reads like a personal site, each section opening below the last once the one above is answered, with its heading taking the focus. The masthead (cover, portrait, name, headline, bio) and the summary bar; "Ways to work with me", the meeting types as full-width editorial entries, each naming its length, where it is held and, for a paid type, its price, then its whole description (a type a direct link chose shows alone), with a link down to them under a long bio; then the calendar and the day's times; then "A little about you": the meeting type's questions one at a time with Continue, then where to meet, the form, a paid type's price and the submit at the end. The summary bar (the organiser's portrait and name, then "Intro call · Thu 9 Oct · 10:30") follows the visitor once a type is chosen and jumps back to any section. There is no Next and no page to go back to. The confirmation replaces everything below the masthead; the masthead stays. The address follows the facts, replacing the history entry, so the browser's Back leaves the page.

## Look

One continuous page on the scheme's canvas, with the cover band across its top and the portrait overlapping the band's lower edge. Serif headings in one of four pairings (Inter with Source Serif 4, Source Sans 3 with Lora, Inter with Fraunces, or the system's own), on warm, low-saturation grounds with one strong accent: Ivory, Sage, Harbour and Blush light, Dusk and Ink dark. Each scheme keeps its own mode; the page never follows the visitor's system. It never has a background behind the page: the cover is the page's hero, not glass over an image or video. The booking page has no card: the cover runs edge to edge, every section sits in one centred reading column of 40rem, separated by space and a hairline, the meeting types are ruled entries with their facts on one line and the chosen one marked by the accent, and the summary bar, with the organiser's portrait and name, sticks on the canvas; the payment pages that follow a paid booking have no card either, and the meeting and poll pages keep a card in the same column.

## Options

A scheme (Ivory, Sage, Harbour, Blush, Dusk or Ink, or a custom seed colour), a font pairing (Classic, Literary, Editorial or Quiet), a corner radius and a cover (one of seven presets or an upload). The headline and bio come from Profile Settings. Defaults: Ivory, the Classic pairing, soft corners and the elegant still life cover.

## Voice

Folio's voice is **personal**, the brief below. Its words for the shared booking lines are in `Folio.Voice`; its own moments' lines (the time prompt, the details, an empty month, the confirmation) follow separately.

- **Tone:** first person, warm, unhurried, like the organiser's own website. Sentences, not labels.
- **Rules:** "I" and "you"; section headings are phrases; the button says what happens next; no jargon like "slot" or "meeting type".
- **Lines:** section "Ways to work with me" (no instruction label; with no meeting types "I'm not taking new bookings at the moment."); time prompt "When suits you?"; a fully booked month "I'm fully booked this month." with "Show my next free day" ("I have no free times at the moment." when none is free); details "A little about you"; button "Book our session", "Request this time" when the organiser approves each booking, "Continue to payment" for a paid type (the shared line); confirmation "See you on Thursday 10 September 2026, Mia" ("See you on Thursday 10 September 2026 instead, Mia" after a move; "Thank you. I'll reply to your request soon." while the organiser decides, above the shared sentence naming the visitor), then "Book another session"; slot taken "Someone took that time a moment ago. Here are the nearest ones." Words in `Folio.Voice` and Folio's moments, context `folio` of `booking_voice`.

## Axes

The axes are where Folio is going, not only today's page: `flow`, `spatial` and `voice` are the continuous page, the full-bleed layout without a card and the personal voice still to land, not today's paged journey, card and shared copy.

<!-- axes:start -->
| Axis | Value |
|---|---|
| `flow` | `continuous` |
| `entry` | `person_first` |
| `spatial` | `full_bleed_editorial` |
| `time_view` | `month_grid` |
| `conversion` | `bio_and_cover` |
| `voice` | `personal` |
| `surface` | `editorial_print` |
<!-- axes:end -->

## Rubric

Quill and Paper are the closest shipped themes: Folio differs from each on six axes (flow, entry, spatial, conversion, voice and surface), sharing only the month grid. It differs from Rhythm on all seven.
