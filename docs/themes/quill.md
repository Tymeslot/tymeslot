# Quill: the polished professional

## Persona

A consultant, an agency or a professional service that wants its booking page to feel premium and finished, with a background that carries its brand colours. Their visitors are clients and prospects who judge the service by how considered everything around it looks, and who expect to be guided step by step.

## Story

> My clients should feel they are booking someone established. The page should look as considered as my work.

## Journey

`Paged`, the classic journey (`steps:`): the overview (the meeting types), the schedule (a month calendar, then the chosen day's times), the questions when the meeting type has any, the booking form, then the confirmation. A pill step indicator above the card shows where the visitor is. Nothing is defaulted; the visitor chooses every fact.

## Look

A wide glass card over a gradient, an image or a looping video, with Inter and generous spacing. The card adapts to its own width through container queries; on the schedule step it locks to the viewport, its actions pinned on screen.

## Options

A colour palette (a preset scheme or a custom seed colour) and a background of any kind: a gradient preset, a solid colour, an image (preset or upload) or a video (preset or upload). Defaults: the default scheme over the Aurora gradient.

## Voice

Polished and friendly. The shared booking copy is Quill's voice.

- **Tone:** confident, warm and businesslike; it welcomes rather than instructs.
- **Rules:** short, plain labels; one exclamation mark at most, in the welcome; the organiser introduced by name when there is one.
- **Lines:** heading "Let's Connect!"; greeting "Hi! I'm Sarah Rodriguez."; instruction "Pick an option below."; button "Next".

## Axes

<!-- axes:start -->
| Axis | Value |
|---|---|
| `flow` | `paged_wizard` |
| `entry` | `meeting_type_first` |
| `spatial` | `wide_card` |
| `time_view` | `month_grid` |
| `conversion` | `atmosphere` |
| `voice` | `polished` |
| `surface` | `glass` |
<!-- axes:end -->

## Rubric

Rhythm is the closest shipped theme: the two differ on spatial (a wide card against a centred one) and time view (a month grid against a week strip), two axes, under the rubric's three. `theme_rubric_test.exs` exempts the pair by name until Rhythm's own voice lands, which makes three.

## Ideas within the story

Small, each its own commit with a reviewed visual pass, never a redesign:

- The step indicator shows what was chosen: the pills read "Intro call" and "Thu 9 Oct, 10:30" once known, and each pill returns to its moment, which suits the polished, in-control story.
- A credentials line: the overview shows the organiser's headline under their name, for the established professional.
