# Paper: the one who just wants it to work

## Persona

Someone who used Calendly or cal.com, a team that white-labels its page, an organiser whose own brand must come first. Their visitors want to book and get on with their day, and the page should never get in the way. They find Quill and Rhythm too much.

## Story

> I don't want my booking page to have a personality. I want it clear, fast and in my colour, so people book and get on with their day.

## Journey

`Paged`, the classic journey (`steps:`) on one card, with no step indicator: the overview (the organiser's introduction beside the meeting types as one bordered list, each with its length, locations and price), the schedule (a month calendar with the chosen day's times, or a week of free times where one click picks the day and the time together), the questions one at a time when the meeting type has any, the booking form under a quiet summary of the chosen meeting and time, then the confirmation with the details and where they were sent. Nothing is defaulted; the visitor chooses every fact. Paper's next step is two working screens: choose, then schedule, questions and details together on one screen.

## Look

One flat card on the tone's canvas (neutral, cool or warm), light, dark or following the visitor's system, with one accent colour. The card is 40rem, widening to 64rem for the overview and the month schedule and to 72rem for the week, and lays its panes out by its own width. System font, Inter or IBM Plex Sans; tabular numerals for times. The organiser's logo, when uploaded, sits top-left of every card. It never has a background behind the card: no gradient, image, video or glass.

## Options

A tone (neutral, cool or warm, or a custom seed colour), a colour mode (light, dark or automatic), an accent (nine presets), a font (system, Inter or IBM Plex Sans), a corner radius, a calendar view (a month calendar or a week of free times) and a logo. Defaults: the neutral tone, the automatic colour mode, the Tymeslot accent, the system font, soft corners and the month calendar, with no logo.

## Voice

Today Paper shares the booking copy every theme shares, its heading naming the organiser ("Schedule with Ana Silva") and its confirmation headline its own ("Booking confirmed"). Its own voice, **neutral**, is the brief below; it lands as Paper's voice module.

- **Tone:** plain, short, invisible. It never talks about itself or the organiser's personality.
- **Rules:** imperative labels, no exclamation marks, no greetings, numbers before words.
- **Lines:** heading "Book a meeting with Ana Silva"; type prompt "Select a meeting type"; time prompt "Select a date and time"; empty "No times available this week"; button "Confirm booking"; confirmation "Booking confirmed"; slot taken "That time was just booked. Choose another."

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
