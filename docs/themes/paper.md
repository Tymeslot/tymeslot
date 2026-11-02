# Paper: the one who just wants it to work

## Persona

Someone who used Calendly or cal.com, a team that white-labels its page, an organiser whose own brand must come first. Their visitors want to book and get on with their day, and the page should never get in the way. They find Quill and Rhythm too much.

## Story

> I don't want my booking page to have a personality. I want it clear, fast and in my colour, so people book and get on with their day.

## Journey

`Navigators.Paged`, two working screens, then the confirmation. The first (`:overview`) lists the meeting types beside the organiser; choosing one goes straight on. A meeting type that offers several lengths asks which one on a screen between the two (`:length`), the lengths as the overview's list; choosing one goes straight on, and every other type passes it over. The second (`:schedule`) holds the meeting's details, the picker (a month calendar with the day's times, or a week of times, by the `calendar_view` option) and, once a time is picked, the details part below it: the meeting type's questions, all at once, above the form, then where to meet, the form and the submit. There is no Next on the second screen; one submit sends the answers and the details together, and a question the submission refuses shows its error under it. Back goes straight from the second screen to the meeting types. A meeting type's own link opens on the second screen, with no Back. The address follows the facts: `/:username`, `/:username/:slug` once a type is chosen, `/:username/:slug/book` once a time is, `/:username/thank-you` on the confirmation.

## Look

One flat card on the palette's canvas, light, dark or following the visitor's system. Each palette is one of Quill and Rhythm's colour families, as a light set on a pale tint of its colour and a dark set on the ground those themes use. The card is 40rem, widening to 64rem for the overview and the month schedule and to 72rem for the week, and lays its panes out by its own width. System font, Inter or IBM Plex Sans; tabular numerals for times. The organiser's logo, when uploaded, sits top-left of every card. It never has a background behind the card: no gradient, image, video or glass. The timezone sits above the times on every view. On the second screen the details part follows the picker under a hairline rule, aligned under the picker once the card shows the details column beside it, in a reading width of its own: the chosen time with its icon and "Change time", the questions one under another, then the form, a paid type's price above the submit.

## Options

A colour palette (eight presets, or a custom seed colour that derives both sets), a colour mode (light, dark or automatic), a font (system, Inter or IBM Plex Sans), a corner radius, a calendar view (a month calendar or a week of free times) and a logo. Defaults: the Default Turquoise palette, the automatic colour mode, the system font, soft corners and the month calendar, with no logo.

## Voice

Paper speaks in its own voice, **neutral**, which is the brief below. `Paper.Voice` words the shared booking lines (heading "Book a meeting with Ana Silva", "Select a meeting type", "Confirm booking", "Reschedule meeting", the slot-taken notice, the times' heading and prompt, the held request) and gives no greeting; its pickers' prompts, empty notices and confirmation headline and message are its components' own lines. A line that would read the same in Paper's words keeps the shared copy: the paid and request labels, the "with Ana Silva" fragment, and the question inputs' "Yes" and "No".

The question inputs' own lines (a select's empty choice, "Yes", "No", a note's acknowledgement) are voice keys too, not form controls every theme shares: their shared wording is the line each input had before, so Quill, Rhythm and Folio read as they did, and Paper words the two that break its voice ("Select an option", "I have read this").

- **Tone:** plain, short, invisible. It never talks about itself or the organiser's personality.
- **Rules:** imperative labels, no exclamation marks, no greetings, numbers before words.
- **Lines:** heading "Book a meeting with Ana Silva" (no greeting); type prompt "Select a meeting type"; time prompt "Select a date and time" (the week's bar: "Select a time"); the day's times "Available times", "Select a date" before one is chosen, and no prompt at all in a month with no free day; empty "No times available this week" ("this month" in the month view); details "Enter your details", the chosen time with "Change time"; form "Name", "Email", "Message (optional)"; questions "Select an option" for a select's empty choice, "I have read this" under a note; button "Confirm booking" ("Continue to payment" for a paid type, "Reschedule meeting" for a move; "Sending…" while it is sent); confirmation "Booking confirmed" with "Your meeting with Ana Silva is confirmed." ("Request sent" with "Your request to Ana Silva has been sent." while the organiser decides, "Meeting rescheduled" with "Your meeting with Ana Silva has been rescheduled." after a move; never the guest's name), then "Book another meeting"; slot taken "That time was just booked. Choose another." Words in `Paper.Voice` and Paper's components, context `paper` of `booking_voice`; the form's labels and the paid button are shared lines.

## Axes

The axes are where Paper is going, not only today's page: `flow` and `voice` are the two working screens and the neutral voice still to land, not today's paged journey and shared copy. The time view is the default calendar view; an organiser can switch Paper to a week of free times.

<!-- axes:start -->
| Axis | Value |
|---|---|
| `flow` | `two_screen` |
| `entry` | `meeting_type_first` |
| `spatial` | `split_card` |
| `time_view` | `month_grid` |
| `conversion` | `none` |
| `voice` | `neutral` |
| `surface` | `flat_light_card` |
<!-- axes:end -->

## Rubric

Quill is the closest shipped theme: the two differ on flow, spatial, conversion, voice and surface, five axes. Paper differs from Rhythm on six (those five and the time view) and from Folio on six (flow, entry, spatial, conversion, voice and surface).
