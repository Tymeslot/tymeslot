# Folio: the person who is the product

## Persona

Coaches, therapists, consultants, writers and freelancers whose booking page is in effect their homepage. Visitors arrive from a profile link and want to know who this is before they book.

## Story

> People book me, not a time slot. Before they pick a date, they should know who I am, what I do, and whether we're a fit.

## Journey

`Paged`, the classic journey (`steps:`), with no step indicator: the overview (the full masthead, with the cover, the organiser's portrait, name, headline and bio, then the meeting types as cards with their descriptions in full), the schedule (a slim masthead, then one column with the meeting's length, the timezone, a month calendar and the chosen day's times), the questions one per page when the meeting type has any, the booking form under a summary of the chosen time, then the confirmation with the meeting's details and the visitor's answers. Nothing is defaulted. Folio's next step is one continuous page that reads like a personal site, each section unlocking below the last with a sticky summary bar, and no card at all.

## Look

One card on the scheme's canvas, a reading column of 46rem, with the cover band across its top and the portrait overlapping its lower edge; from the schedule on, the band is slim and the portrait small. Serif headings in one of four pairings (Inter with Source Serif 4, Source Sans 3 with Lora, Inter with Fraunces, or the system's own), on warm, low-saturation grounds with one strong accent: Ivory, Sage, Harbour and Blush light, Dusk and Ink dark. Each scheme keeps its own mode; the page never follows the visitor's system. It never has a background behind the card: the cover is the page's hero, not glass over an image or video.

## Options

A scheme (Ivory, Sage, Harbour, Blush, Dusk or Ink, or a custom seed colour), a font pairing (Classic, Literary, Editorial or Quiet), a corner radius and a cover (one of seven presets or an upload). The headline and bio come from Profile Settings. Defaults: Ivory, the Classic pairing, soft corners and the elegant still life cover.

## Voice

Folio's voice is **personal**, the brief below. Its words for the shared booking lines are in `Folio.Voice`; its own moments' lines (the time prompt, the details, an empty month, the confirmation) follow separately.

- **Tone:** first person, warm, unhurried, like the organiser's own website. Sentences, not labels.
- **Rules:** "I" and "you"; section headings are phrases; the button says what happens next; no jargon like "slot" or "meeting type".
- **Lines:** section "Ways to work with me" (no instruction label); button "Book our session", "Request this time" when the organiser approves each booking, "Continue to payment" for a paid type (the shared line); slot taken "Someone took that time a moment ago. Here are the nearest ones." Words in `Folio.Voice`, context `folio` of `booking_voice`.

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
