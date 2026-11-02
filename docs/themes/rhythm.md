# Rhythm: the mood setter

## Persona

A creative (a photographer, a musician, a studio, a wellness space) whose booking page should feel like stepping into their space. Their visitors come for the experience as much as the appointment, and the page is the first taste of it.

## Story

> When someone books me, I want them to feel the atmosphere first: motion, mood, then a time.

## Journey

`Paged`, the classic journey (`steps:`), its moments sliding into one another with no step indicator: the overview (the meeting types; choosing one goes straight on), the schedule (a week strip, then the chosen day's times), the questions when the meeting type has any, the booking form, then the confirmation. Nothing is defaulted.

## Look

A narrow dark glass card over a looping video, compact, the card a fixed viewport box whose own regions scroll. The video is the atmosphere; the card stays small so it never hides it. Each step slides in as it opens, and not at all under reduced motion.

## Options

A colour palette (a preset scheme or a custom seed colour) and a background of any kind: a gradient preset, a solid colour, an image (preset or upload) or a video (preset or upload). Default: Rhythm's own background video.

## Voice

Today Rhythm shares Quill's polished copy, its heading naming the organiser ("Schedule with Kai"). Its own voice, **evocative**, is the brief below; it lands as Rhythm's voice module, and this sheet's `voice` axis changes with it.

- **Tone:** sensory, calm, present tense; it sets a mood rather than giving instructions.
- **Rules:** short lines; verbs of arriving and stepping in; no exclamation marks; never corporate.
- **Lines:** heading "Step into a session with Kai"; type prompt "Choose your session"; time prompt "Find your moment"; details "Tell me who's coming"; button "Hold this time"; confirmation "It's set. Thursday, 10:30."; slot taken "That moment just passed to someone else. Here's the next."

## Axes

<!-- axes:start -->
| Axis | Value |
|---|---|
| `flow` | `paged_wizard` |
| `entry` | `meeting_type_first` |
| `spatial` | `centred_card` |
| `time_view` | `week_strip` |
| `conversion` | `atmosphere` |
| `voice` | `polished` |
| `surface` | `glass` |
<!-- axes:end -->

## Rubric

Quill is the closest shipped theme: the two differ on spatial and time view, two axes, under the rubric's three. `theme_rubric_test.exs` exempts the pair by name; the commit that lands Rhythm's evocative voice removes the exemption, since voice becomes the third difference.

## Ideas within the story

Small, each its own commit with a reviewed visual pass, never a redesign:

- Rhythm's own voice (the brief above): copy only, through its voice module. This is the one planned next.
- A mood line: an optional tagline the organiser writes, set large over the video on the first slide before the card appears, so the atmosphere comes first, as the story says.
- Slides that follow the video: slide transitions take their timing from the background's motion preset instead of one fixed duration.
