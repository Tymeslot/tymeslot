# Theme Development Guide

This guide explains how to create new themes for Tymeslot.

## Architecture Overview

The theme system uses a centralized registry pattern that eliminates magic strings and provides type-safe theme access.

### Key Components

1. **Theme Catalog** (`Tymeslot.Themes.Catalog`) - Domain source of truth for theme *facts* (id, key, name, heading style, customisation spec, status)
2. **Theme Registry** (`TymeslotWeb.Themes.Core.Registry`) - Web layer; merges catalog facts with presentation bindings (the theme module)
3. **Theme Behaviour** (`TymeslotWeb.Themes.Core.Behaviour`) - The contract a theme module fulfils; `use TymeslotWeb.Themes.Core.Theme` generates it
4. **SchedulingLive Macro** (`TymeslotWeb.Themes.Shared.SchedulingLive`) - Injects all common LiveView callbacks; a theme's `live.ex` is built on it
5. **Shared State Machine** (`TymeslotWeb.Themes.Shared.StateMachineHelpers`) - Owns state transitions and routing for all themes (no per-theme state machine)
6. **Shared Context** (`TymeslotWeb.Themes.Shared.*`) - Shared helpers, handlers, and components
7. **Customisation spec** (`Tymeslot.ThemeCustomizations.Spec`) - Per-theme option groups, defaults, validation and CSS tokens; each Catalog entry names its spec module
8. **Dispatcher** (`TymeslotWeb.Themes.Core.Dispatcher`) - The LiveView every booking route hits; it resolves the theme's module through `ThemeInfo` (the Registry's binding) and delegates the LiveView callbacks to it
9. **Wrapper Components** (per-theme): the theme's background and wrapper classes around the shared `Shared.Components.ThemeShell`, which renders the page chrome

## Quick Reference

### File Structure for a Theme

```
lib/tymeslot_web/themes/[theme_name]/
├── theme.ex                    # One `use TymeslotWeb.Themes.Core.Theme`
├── onboarding_preview.ex        # Optional: the theme in the onboarding wizard
├── scheduling/
│   ├── live.ex                 # Main LiveView (uses the SchedulingLive macro)
│   ├── wrapper.ex              # Background and wrapper classes around ThemeShell
│   └── components/
│       ├── overview_component.ex
│       ├── schedule_component.ex
│       ├── custom_questions_component.ex   # Renders the conditional :questions step
│       ├── booking_component.ex
│       └── confirmation_component.ex
├── meeting/
│   ├── reschedule.ex
│   ├── cancel.ex
│   └── cancel_confirmed.ex
├── poll/
│   └── voting.ex               # Poll voting page shell
└── payment/                    # Payment return page shells (Stripe success / cancel)
    ├── processing.ex
    └── cancelled.ex
```

> **No per-theme `state_machine.ex`.** State transitions live in the shared
> `TymeslotWeb.Themes.Shared.StateMachineHelpers`. Both Quill and Rhythm have
> deleted their local state machine. See [Common Patterns](#common-patterns).
>
> **Payment return pages are shared.** `Shared.PaymentReturnLive.Processing` and `.Cancelled` serve `/themes/<key>/payment-processing/<id>` and `/themes/<key>/payment-cancelled/<id>` for every theme, assigning `:theme_id` from the slug so the layout loads the theme's own stylesheet. A theme only draws its shell, in `payment/processing.ex` and `payment/cancelled.ex`, around `Shared.PaymentReturnComponents`; it adds no route and no LiveView.
>
> **`meeting/`, `poll/` and `payment/` are optional.** A theme that names a `page_shell:` (Quick Start step 3) writes none of the six page modules: it gets them from `Shared.DefaultPages`.
>
> Themes may add their own internal structure beyond the above; Rhythm, for
> example, keeps a theme-local `shared/` directory (`organizer_header.ex`) for
> components reused only within that theme.

```
assets/css/scheduling/themes/[theme_name]/
├── theme.css                   # Main entry point (imports shared primitives + modules)
└── modules/
    ├── variables.css           # Design tokens (colors, spacing, typography)
    ├── base.css                # html, body, theme wrapper, root grid
    ├── iframe.css              # Theme-specific embed rules (shared ones: shared/embed.css)
    ├── typography.css          # Text styles with fluid clamp() sizes
    ├── video.css               # Video background (if supported)
    ├── overview.css            # Organizer profile + avatar
    ├── calendar.css            # Calendar grid + container queries
    ├── time-slots.css          # Time slot grid + container queries
    ├── schedule-header.css     # Schedule header + timezone selector
    ├── booking-form.css        # Booking form + container queries
    ├── custom-questions.css    # the theme's own part of the questions step (optional)
    ├── confirmation.css        # Confirmation + container queries
    └── language-switcher.css   # Language switcher (theme-specific treatment)
```

> Components every theme shares (preview and approval notices, the flash toast, polls, payment return pages, guest and location fields, the questions step's tiles and option cards, language switcher structure, slot list, timezone picker, week grid, default meeting pages) are not per-theme modules: their CSS lives in `assets/css/scheduling/shared/components/`, which each `theme.css` imports, and a theme styles them by defining the tokens each file lists in its header (see [Modular Structure](#modular-structure) and [Token contract](#token-contract)).

> The module breakdown is **per-theme, not canonical** — themes are free to split
> further. Quill (glassmorphism) splits its UI into `glass-card.css`, `buttons.css`,
> `animations.css`, `spinner.css`, `steps.css`, `timezone.css`, `meeting-details.css`,
> and `text-utilities.css`; Rhythm keeps a single `components.css`. Only the broad
> concerns above are common to both. The booking-form file is `booking-form.css`
> (not `booking.css`).

> **Never name a Tailwind utility in a theme selector** (`.text-3xl`, `.font-bold`, `.container`, `.hidden`, or a compound hook such as `.grid.grid-cols-7`). Theme modules are unlayered, so such a rule overrides that utility on every element of the booking page, shared and core components included. Put a theme or BEM class on the element (`quill-container`, `calendar-month-grid`, `step-label--current`) and style that; element selectors (`h1`) are fine.

### Behaviour Callbacks

Generated by `use TymeslotWeb.Themes.Core.Theme` (see Quick Start step 3):

```elixir
@callback live_view_module() :: module()
@callback metadata() :: %{preview_image: String.t(), description: String.t()}
@callback render_meeting_action(map(), atom()) :: Phoenix.LiveView.Rendered.t()
@callback render_poll_action(map()) :: Phoenix.LiveView.Rendered.t()
@callback render_payment_page(map(), :processing | :cancelled) :: Phoenix.LiveView.Rendered.t()
@callback onboarding_preview(map()) :: Phoenix.LiveView.Rendered.t()  # optional
@callback option_panels() :: %{module() => module()}      # the :option_panels option, default %{}
```

`onboarding_preview/1` draws the theme in the onboarding wizard (`:thumbnail` for the picker tile, `:card` for the live preview card around a shared `header` slot). It defaults to a generic mock; Quill and Rhythm implement it in `themes/<theme>/onboarding_preview.ex` with the helpers in `TymeslotWeb.OnboardingLive.PreviewParts`. Both variants draw with a colour map (`primary`, `accent`, `background`, `surface`, `text`, `text_secondary`) that `PreviewParts.colors/1` reads from the theme's resolved `tokens/2`, so a preview follows whatever the spec resolves; a colour the tokens leave out falls back to a neutral default. The colour row beside it lists the spec's `onboarding_choices/0`, each name translated through the `dashboard_appearance` domain as the dashboard's panels translate it, and is hidden when that is `nil`.

`option_panels/0` maps each of the theme's own option groups to its dashboard panel (`use TymeslotWeb.Themes.Core.Theme, ..., option_panels: %{MyGroup => MyPanel}`); the shared groups have built-in panels.

### Shared Modules You'll Use

| Module | Purpose |
|--------|---------|
| `LiveHelpers.Mount` | Mounting the scheduling LiveView and applying URL parameters (timezone, organiser, customisation, owner preview, calendar subscription) |
| `LiveHelpers.StepEntry` | What entering the schedule, questions and booking steps sets up, and meeting-type assignment |
| `LiveHelpers.Tracking` | First-touch UTM and referrer attribution (`assign_tracking/2`, `tracking_path/2`) |
| `EventHandlers` | Page-level events outside the steps: language switcher, timezone search |
| `SchedulingFlow` | The booking flow itself: every step event, step transitions (`transition_to/3`), step entry (`handle_state_entry/3`) and step-indicator navigation (`navigate_to_step/2`) |
| `InfoHandlers` | The LiveView's mailbox: `route/2` dispatches availability results, slot loading, calendar refreshes and payment broadcasts |
| `StepEvents` | `update/2` and `handle_event/3` every step component delegates to; defines the canonical event names a step template may use |
| `SchedulingInit` | Socket state initialization — `assign_theme_state/1` for full scheduling state (prefer this), `assign_base_state/1` for core-only assigns |
| `BookingFlow` | Form validation and submission |
| `LocalizationHelpers` | Date/time/duration formatting: `format_date/1`, `format_duration/1`, `format_booking_datetime/3`, `format_time_by_locale/1` (respects locale 12h/24h setting — always use this for time slot display), `day_name_short/1` (localized weekday abbreviations), `get_week_display/1` (formatted week range string). `format_advance_booking_days/1` (the booking-window phrase in the schedule header, e.g. "2 weeks in advance"), `weekday_headers/0` (translated three-character weekday headers, Sunday first, matching the month grid). Meeting types arrive pre-ordered by the user's configured `sort_order` — never re-sort them in theme components. |
| `BookingText` | The overview step's introductory copy, and `duration_label/1`: the meeting length a step shows, the meeting type's own duration first, else the selected duration. Use it rather than choosing between the two in a template. `price_label(meeting_type, @host_currency, @locale)` is a paid meeting type's price in the organiser's currency, written the way the guest's locale writes amounts, `nil` for a free one. |
| `ConfirmationText` | What the confirmation step announces: `status/1` (`:held`, `:rescheduled` or `:confirmed`; a held booking wins over a reschedule), `held_message/2` and `organizer_fragment/1`. The theme keeps its own headline per status. |
| `Tymeslot.Timezones` | Human-readable timezone display: `Timezones.format/1` — use this in confirmation and booking components instead of string-splitting the IANA timezone identifier |
| `TymeslotWeb.Live.Scheduling.CalendarHelpers` | Calendar/week day generation (`get_week_days/4` — pass `@user_timezone`), `anchor_on_today/1` (opens the calendar on today in the visitor's timezone; never compute "today" in a theme), `anchor_on/2` (positions the month and week on a date), `anchor_on_selection/1` (the schedule-step opening: a bookable chosen or linked day, else today), `untouched?/1` (whether the calendar is still where the page left it), week and month navigation (`handle_week_navigation/2`, `handle_month_navigation/2`; both are shared schedule events, so a theme only renders buttons sending `prev_week`/`next_week` or `prev_month`/`next_month`), availability fetching, slot parsing, `display_range/2` for visible date boundaries. **Note:** this lives under `live/scheduling/`, not `themes/shared/`. |
| `TymeslotWeb.Live.Scheduling.CalendarNavigation` | Navigation boundary checks: `prev_month_disabled?/3`, `next_month_disabled?/4` (pass `@organizer_profile.advance_booking_days`), `prev_week_disabled?/2`, `next_week_disabled?/3` (pass `advance_booking_days`); wire these to nav button `disabled` attributes. `month_nav_label/1` (`:prev` or `:next`) is the translated accessible name of a month calendar's previous or next button that shows only a glyph. Also under `live/scheduling/`. |
| `StateMachineHelpers` | Shared state model and transition logic — `default_states/0`, `states_for/1` (5-step flow when the meeting type has custom fields, 4-step otherwise), `determine_initial_state/1`, `can_navigate_to_step?/3`, `validate_state_transition/3`. Replaces the deleted per-theme state machines. |
| `PathHandlers` | Navigation with locale preservation; `organizer_scheduling_path/1` for back-to-calendar links in cancel/reschedule pages; `calendar_ics_path/1` for the confirmation step's add-to-calendar link (`nil` until the meeting exists, which is what hides the link) |
| `Customization.Helpers` | `assign_theme_customization/3` (assigns `:theme_tokens`, done for you on mount) and `prepare_wrapper_assigns/1`, which derives `@background` (the background descriptor, `@theme_tokens.media[:background]`), `@has_video_background` and `@show_language_switcher` |
| `ThemeStyle` | `theme_style/1` writes the tokens' `<style>` block (the shell calls it); `inline_background/1` turns a gradient, colour or image descriptor into the inline style for your background element |
| `LocaleHandler` | Applies a locale switch to the socket — `handle_locale_change/2`. The language switcher's locale list comes from `Tymeslot.Locales.supported/0` (each entry a `%{code:, name:, country_code:}` map) |
| `SchedulingLive` | Shared LiveView macro: `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: &Wrapper.x/1, steps: %{…}` generates every callback and `render/1`; a theme's `live.ex` is only this `use` |
| `SchedulingPage` | The generated `render/1`: wrapper around the current step, readiness/error message, awaiting-payment screen, overview fallback |
| `VideoSources` | `<.video_sources sources={@background.sources} />` inside your `<video>` |
| `Shared.Components.MeetingDetails` | Shared `meeting_detail_rows/1` component for cancel/reschedule pages; renders date, time, timezone, and organizer rows with icons |
| `Shared.Components.AwaitingPayment` | Shared `awaiting_payment/1` component for the transitional `:awaiting_payment` state in paid embedded bookings — `<AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />` |
| `Shared.CustomQuestions.{Engine, Events, Inputs.Renderer}` | Shared engine, event delegation, and input renderers for the custom-questions step. Your theme's `CustomQuestionsComponent` provides the chrome and delegates `handle_event` to `Events`; `Inputs.Renderer` renders each field type. Its navigation events are the canonical `next_step` and `back_step`, as on every other step. |

## Quick Start

### 1. Create Theme Directory Structure

Create the following directory structure for your new theme:

```
lib/tymeslot_web/themes/aurora/
├── scheduling/
│   ├── components/
│   │   ├── booking_component.ex
│   │   ├── confirmation_component.ex
│   │   ├── custom_questions_component.ex
│   │   ├── overview_component.ex
│   │   └── schedule_component.ex
│   ├── live.ex                 # No state_machine.ex — StateMachineHelpers is shared
│   └── wrapper.ex              # Background and wrapper classes around ThemeShell
├── meeting/
│   ├── cancel.ex
│   ├── cancel_confirmed.ex
│   └── reschedule.ex
├── poll/
│   └── voting.ex
├── payment/
│   ├── cancelled.ex
│   └── processing.ex
└── theme.ex

assets/css/scheduling/themes/aurora/
├── modules/
│   ├── variables.css           # Design tokens (colors, spacing, typography)
│   ├── base.css                # Root layout, theme wrapper
│   ├── iframe.css              # Theme-specific embed rules (required)
│   ├── typography.css          # Text styles with fluid clamp() sizes
│   ├── video.css               # Video background (if supported)
│   ├── overview.css            # Organizer profile (optional)
│   ├── calendar.css            # Calendar grid + container queries
│   ├── time-slots.css          # Time slot grid + container queries
│   ├── schedule-header.css     # Schedule header + timezone selector
│   ├── booking-form.css        # Booking form + container queries
│   ├── custom-questions.css    # the theme's own part of the questions step (optional)
│   ├── confirmation.css        # Confirmation step
│   ├── components.css          # Buttons, inputs, duration cards (or split further)
│   └── language-switcher.css   # Language dropdown
└── theme.css
```

**Tip**: Copy an existing theme (Quill or Rhythm) as a starting point and modify it.

### 2. Register Your Theme

Theme registration is split across **two** modules so the dependency only ever
flows web → domain:

**a. Theme facts** — add an entry to the map `shipped_themes/0` returns in
`lib/tymeslot/themes/catalog.ex` (pure domain data: no module, CSS,
or image references):

```elixir
aurora: %{
  id: "3",
  key: :aurora,
  name: "Aurora",
  heading_style: :generic, # or :named, to open with "Schedule with <organiser>"
  customization_spec: Tymeslot.ThemeCustomizations.AuroraSpec,
  status: :active
}
```

Start a new theme at `status: :beta`: it is hidden from the theme pickers but
reachable with `?theme=<id>`. Switch it to `:active` when it is ready to offer.

The description shown in the dashboard is the theme's own, translated, not a
catalogue fact.

**b. Presentation bindings** — add an entry to `@bindings` (keyed by theme **id**)
in `lib/tymeslot_web/themes/core/registry.ex`:

```elixir
"3" => TymeslotWeb.Themes.Aurora.Theme
```

`Registry` joins the two at compile time (`Catalog.all/0` ⨝ `@bindings`) into the
`theme_definition` the web layer consumes. The two must match: a Catalog entry with no binding, or a binding with no Catalog entry, fails the build with a message naming the id (`Registry.Definitions.build!/2`). Nothing else is bound: the stylesheet
path (`/assets/scheduling-theme-aurora.css`) and the `aurora-theme` class derive
from the key, and the picker's preview image and description come from the theme
module's `metadata/0`. So the theme's CSS directory must be named after its
key: its build configuration (a Tailwind profile writing
`../priv/static/assets/scheduling-theme-aurora.css`, a dev watcher and the
`assets.build`/`assets.minify` entries) is derived from the directories under
`assets/css/scheduling/themes/` through `config/theme_stylesheets.exs`, and
`ThemeStylesheetsTest` fails until every shipped theme has a directory and every
directory is a shipped theme's key. Domain code (profiles, theme customisations)
reads facts from `Catalog` directly and never reaches into the web layer.

### 3. Implement Required Functions

Your theme module is one `use`:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Theme do
  @moduledoc """
  Aurora: northern lights design with a 4-step booking flow.
  """

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Aurora.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/aurora-theme-preview.webp",
    description:
      dgettext_noop("dashboard_appearance", "Northern lights design with a 4-step booking flow.")
end
```

`use TymeslotWeb.Themes.Core.Theme` declares `TymeslotWeb.Themes.Core.Behaviour` and generates every callback. The render callbacks dispatch by convention to `render/1` in modules under your theme's namespace: `Meeting.Reschedule`, `Meeting.Cancel`, `Meeting.CancelConfirmed`, `Poll.Voting`, `Payment.Processing` and `Payment.Cancelled`. A missing one is a compile warning, which the build treats as an error. Or name a shell: `use TymeslotWeb.Themes.Core.Theme, ..., page_shell: &MyTheme.Pages.page_shell/1` gives the theme all six pages from `Shared.DefaultPages`, each shared body inside that function component, which receives `page`, `theme_tokens`, `locale` and `language_dropdown_open` (the last three `nil` on the payment pages) and draws the theme's wrapper and a `booker-card` card. Import `shared/components/manage-pages.css` and set the tokens its header lists. The fixture theme's `pages.ex` is the smallest example. Override a callback (with `@impl TymeslotWeb.Themes.Core.Behaviour`) only if your theme needs a different mapping. An override replaces every clause of that callback, so one that handles only some pages or actions must call `super/2` for the rest. The description must be a `dgettext_noop/2` call; `metadata/0` translates it at call time.

### 4. Test It Works

Add the theme to `TymeslotWeb.ThemeTestMatrix`. `test/tymeslot_web/themes/theme_contract_test.exs`
then holds it to the contract (LiveView, picker metadata, meeting, poll and payment
pages), and the shared flow suites run it through a booking:

```bash
mix test test/tymeslot_web/themes/theme_contract_test.exs
# Run the production checklist
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs
```

The production checklist runs every catalogued theme and checks:
- All meeting types are displayed
- Theme handles edge cases (no meeting types, long names)
- Basic mobile readiness

## CSS Architecture

### Modular Structure

Themes use a **modular CSS architecture** located in `assets/css/scheduling/`:

```
assets/css/scheduling/
├── shared/                        # Shared by every theme
│   ├── entry.css                 # Imported first by every theme.css: Tailwind, primitives, variants, @source
│   ├── tokens.css                # The token contract and the derived tokens
│   ├── reset.css                 # CSS reset
│   ├── fonts.css                 # Self-hosted @font-face rules and the --font-stack-<id> / --font-heading-<id> stacks
│   ├── layout.css                # Fallback radius scale, reCAPTCHA badge, honeypot field, status screens
│   ├── utilities.css             # Loading-spinner animation, hour-picker count badge
│   ├── brand-tokens.css          # Tailwind @theme block for the reCAPTCHA notice
│   ├── background-motion.css     # Background video pause/play toggle
│   ├── embed.css                 # Embed shell rules (booker hook classes)
│   └── components/               # Shared component styles (structure and states; themes set tokens)
│       ├── approval-notice.css
│       ├── booking-fields.css    # Guest and location fields
│       ├── custom-questions.css  # The questions step's yes/no tiles and option cards
│       ├── flash.css             # Core's flash toast, restyled from the theme's tokens
│       ├── language-switcher.css
│       ├── manage-pages.css      # Default meeting pages, for a theme with a page_shell
│       ├── payment-pages.css
│       ├── polls.css
│       ├── preview-notice.css
│       ├── slot-list.css
│       ├── timezone-picker.css
│       └── week-grid.css         # WeekGrid, for a theme with a week view
└── themes/
    ├── quill/                         # Quill theme (glassmorphism) — fine-grained split
    │   ├── modules/
    │   │   ├── variables.css         # Design tokens
    │   │   ├── base.css              # Root layout, theme wrapper
    │   │   ├── iframe.css            # Theme-specific embed rules
    │   │   ├── video.css             # Video background
    │   │   ├── typography.css        # Text styles
    │   │   ├── animations.css        # Keyframes / transitions
    │   │   ├── glass-card.css        # Glassmorphism container (container query context)
    │   │   ├── buttons.css           # Buttons
    │   │   ├── spinner.css           # Loading spinner
    │   │   ├── meeting-details.css   # Meeting detail rows
    │   │   ├── text-utilities.css    # Text helpers
    │   │   ├── steps.css             # Step indicator
    │   │   ├── schedule-header.css   # Schedule header
    │   │   ├── timezone.css          # Timezone selector
    │   │   ├── calendar.css          # Calendar + container queries
    │   │   ├── time-slots.css        # Time slots + container queries
    │   │   ├── booking-form.css      # Booking form
    │   │   ├── custom-questions.css  # Its own part of the questions step
    │   │   ├── overview.css          # Organizer profile
    │   │   ├── confirmation.css      # Confirmation step
    │   │   ├── meeting-pages.css     # Cancel and reschedule pages
    │   │   └── language-switcher.css # Language dropdown
    │   └── theme.css                 # Entry point
    └── rhythm/                        # Rhythm theme (video backgrounds) — coarser split
        ├── modules/
        │   ├── variables.css
        │   ├── base.css              # Root layout + container query context (.scheduling-box)
        │   ├── typography.css
        │   ├── video.css
        │   ├── overview.css
        │   ├── schedule-header.css
        │   ├── booking-form.css
        │   ├── custom-questions.css
        │   ├── confirmation.css
        │   ├── components.css        # All UI controls in one file
        │   ├── language-switcher.css
        │   ├── calendar.css
        │   ├── time-slots.css
        │   └── iframe.css
        └── theme.css
```

The two themes deliberately split their modules at **different granularities** —
there is no fixed module list. Quill breaks UI controls into many small files;
Rhythm consolidates them into `components.css`. Match whichever style suits your
theme; only `variables.css`, `base.css`, and `iframe.css` are universally expected.

Each file under `shared/components/` carries a shared component's structure and states, and lists in its header the tokens a theme sets for its look, in its `variables.css` (`custom-questions.css`'s `--option-*` tokens are all optional). Where the themes differ by a whole treatment rather than a value, the declarations stay in the theme's own module under the same selector. `layout.css`'s radius scale (`--radius-sm` to `--radius-full`) is a fallback a theme may override.

### Theme CSS Structure

Each theme's `theme.css` imports the shared entry, then the shared token file right after its own `variables.css`, then its modules:

```css
@import "../../shared/entry.css";        /* Tailwind, shared primitives, variants, @source */

@import "./modules/variables.css";       /* the theme's tokens (MUST come first) */
@import "../../shared/tokens.css";       /* derived tokens (see Token contract) */
@import "./modules/base.css";
@import "../../shared/embed.css";        /* shared embed rules on the booker hook classes */
@import "./modules/iframe.css";          /* the theme's own embed rules */
/* …the theme's own modules, and the shared/components/*.css it uses (every REQUIRED_SHARED_IMPORTS file among them) */
```

### Token contract

`scheduling/shared/tokens.css` is the contract every theme builds on. Its header lists the five kinds of token (inputs, roles, shared-component tokens, derived tokens, defaults). A theme's `variables.css` sets the inputs and defines every role and shared-component token; the derived tokens (`--theme-primary-focus`, `--theme-primary-tint`, `--theme-primary-glow`, `--focus-ring`, `--shadow-{primary,success,danger,warning,info}-*`) are computed with `color-mix()` from the inputs, so a custom palette reaches them automatically. Inputs are only ever overridden on `:root`, never on a wrapper element, or the derived tokens stop following them.

`mix css.check_tokens` fails when a theme's `variables.css` lacks one of the tokens in its required list (the `--space-*` scale, the inputs, the roles, the `--status-*` tokens, the per-component tokens each shared file lists in its header, and the scale tokens below). The shared files read these scale tokens from the theme, so a theme that left one out would silently drop every declaration reading it:

- Borders: `--border-subtle`, `--border-light`, `--border-medium` (timezone picker, booking fields)
- Surfaces: `--surface-subtle`, `--surface-light`, `--surface-medium`, `--surface-intense` (timezone picker, booking fields)
- Error tint: `--theme-error-light` (booking fields)
- Type: `--theme-font-family` (a `var(--font-stack-<id>)`, see *Fonts* below), `--theme-font-size-3xs`, `-2xs`, `-xs`, `-sm`, `-base`, `-md`, `-lg`, `-2xl`, `-3xl`; `--letter-spacing-wide`
- Sizes and effects: `--space-hairline`, `--icon-sm`, `--shadow-md`

`shared/tokens.css` defaults 26 tokens on `:where(:root)`, so a theme defines them only to change them: the border widths, font weights, line heights and transitions, `--z-dropdown`, `--flag-height`, `--dropdown-max-height`, `--readiness-card-max-width`, the role aliases `--line-1`, `--line-2`, `--surface-1` and `--notice-warning`, the solid pairs `--theme-primary-solid(-hover)` and `--theme-accent-solid`, the `--chrome-*` tokens over a background photo or video, and `--print-line`. A theme's `:root` outranks them whatever the import order.

The radius scale they read (`--radius-sm`, `-md`, `-lg`, `-xl`, `-2xl`, `-full`) has fallback values in `shared/layout.css`, so a theme defines those only to change them.

`--density` is the one role `shared/tokens.css` defines itself, as `1` on `:root`. A theme's spacing may multiply by it (`calc(var(--space-md) * var(--density))`); a theme that declares the density option gets its value from the server's block, which outranks `:root`, and a theme without it leaves it at `1`.

The required list cannot fall behind the shared styles: the check also collects every `var()` that `shared/**/*.css` reads without a fallback, and fails, naming the token, when one is neither defined in a shared file nor on the list. A new token read in a shared file is therefore added to `REQUIRED_TOKENS` in `scripts/test_css_tokens.sh`, to every theme's `variables.css`, and to this list.

### Fonts

`scheduling/shared/fonts.css`, imported by `shared/entry.css`, declares the self-hosted fonts (files under `priv/static/fonts/`, whose `README.md` records their source, version and checksums) and, on `:root`, one body stack and one heading stack per font id: `--font-stack-<id>` and `--font-heading-<id>` for `system`, `inter`, `plex`, `classic`, `literary`, `editorial` and `quiet`. A theme sets `--theme-font-family` in its `variables.css` to one of the body stacks (`--theme-font-family: var(--font-stack-inter);`) and, where its headings differ, `--theme-font-heading` to a heading stack; `--theme-font-heading` defaults to the body family (`shared/tokens.css`). Never name a font family in a theme: a family nothing declares is silently replaced by the system font. Quill and Rhythm use `var(--font-stack-inter)`; `SharedFontsTest` fails for a shipped theme whose `--theme-font-family` is not one of the shared stacks. A face is only downloaded when something renders in it, so the unused ones cost nothing.

### Intrinsic Responsiveness

Themes use **CSS container queries** and **fluid sizing** instead of viewport breakpoints. Each component file owns its base styles, container queries and component-level iframe overrides in one place; the shared embed shell is in `shared/embed.css`.

**Container query context:** The primary content container (`.scheduling-box` for Rhythm, `.glass-morphism-card` for Quill) has `container-type: inline-size; container-name: scheduling;`. All child components can use `@container scheduling (...)` queries.

**Fluid sizing with `clamp()` and `cqi` units:**
```css
.slide { padding: clamp(0.75rem, 3cqi, 1.5rem); }
.calendar-day { padding: clamp(0.25rem, 1cqi, 0.75rem); }
```

The `cqi` unit resolves against the nearest ancestor with `container-type: inline-size`.

**Fluid grids with `auto-fit`:**
```css
.slot-list__grid { grid-template-columns: repeat(auto-fit, minmax(5rem, 1fr)); }
```

**Container queries for discrete layout switches:**
```css
@container scheduling (min-width: 480px) {
  .calendar-monthly { display: grid; }
  .calendar-weekly { display: none; }
}
```

**What stays as `@media`:**
- Height-based switches (`@media (max-height: ...)`) — container height queries have limited support. Such a switch is for a page opened on its own: nest its rules in `:where(html:not([data-embedded]))`, so it never applies in an embed, whose height follows its content (`mix css.check_tokens` checks it; see `shared/embed.css`)
- `prefers-reduced-motion` and `print`, co-located in the component they affect
- Elements outside the container query context (e.g. language switcher, which sits outside the primary content container) — these must use viewport `@media` queries since `@container` only matches descendants of the container element

**Browser support:** Safari 16+, Chrome 105+, Firefox 110+.

### Template Guidelines

Templates define structure, CSS defines appearance:
- Use semantic CSS class names describing what the element IS (`.calendar-grid`, `.duration-card`)
- No visual classes in templates (no `rounded-xl`, `shadow-lg`)
- No layout classes in templates (no `flex-row`, `grid-cols-2`)
- No responsive classes in templates (no `sm:`, `md:`, `lg:`)
- Each theme owns its step templates. The shared components listed below have fixed markup: a theme styles their classes in its own CSS and never restructures them.

### Shared Components

The **step layouts** are theme-owned: duration cards, calendar day buttons and the booking step's card are rendered and styled by each theme. Pieces whose behaviour (accessibility, grouping, events, wording, anti-spam) must not drift between themes are shared components with fixed markup and block-element class names; each theme styles those classes in its own CSS.

Shared across themes:

- **`Shared.Components.CustomAnswers`** (`custom_answers/1`): the confirmation step's "Your answers" list. Classes `custom-answers`, `custom-answers__heading`, `__list`, `__row`, `__label`, `__value`.
- **`Shared.Components.ProfileIntro`** (`headline/1`, `bio/1`): the organiser's headline and bio (`Profiles.update_intro/2`). Pass `profile={@organizer_profile}`; each renders nothing when its field is empty. The headline is `p.profile-intro__headline`; the bio is `div.profile-intro__bio` holding one `p.profile-intro__paragraph` per blank-line-separated block, the organiser's single line breaks as `<br>`, everything escaped. Tests select them by `data-testid="profile-headline"` and `"profile-bio"`. Quill and Rhythm do not show them; the fixture theme's overview is the worked example.
- **`Shared.Components.SlotList`** (`slot_list/1`): the schedule step's time-slot panel, with the heading, the screen-reader status line, flat and by-hour grouping, the slot buttons, and the prompt, loading, error and fully-booked states. Classes `slot-list`, `slot-list__heading`, `__body`, `__groups`, `__period`, `__period-label`, `__grid` (`--minutes`), `__slot` (`--selected`, `--hour`, `--expanded`), `__hour-label`, `__hour-count`, `__prompt`, `__loading`, `__error`, `__empty`. Pass `heading_tag`/`period_tag` to fit your page's heading outline, and the `:loading`, `:error` and `:empty` slots only if your theme renders those states with its own markup. Tests select slots by `data-testid="time-slot"` and `"slot-hour"`, never by class.
- **`Shared.Components.WeekGrid`** (`week_grid/1`): a week of free times on one screen, for a theme with a week view: one column per day from the week's Monday, each listing its times, with previous and next week controls; one click on a time picks the day and the time together (`select_slot`). Classes `week-grid` (`--loading`), `week-grid__nav`, `__nav-button` (`--prev`, `--next`), `__nav-icon`, `__range`, `__days`, `__day` (`--today`), `__day-heading`, `__day-name`, `__day-date`, `__slots`, `__slot` (`--selected`), `__empty`, `__loading`, `__error`, `__jump`; the shared structure is `scheduling/shared/components/week-grid.css` (import it after `shared/tokens.css`; it reads the contract tokens plus `--week-grid-gap`), and the grid is its own container (`week-grid`), showing seven days, then three, then one as it narrows. Pass the flow's week assigns (`week_slots={@week_slots}`, `loading={@week_slots_loading}`, `error={@week_slots_error}`) and `week_start={@current_week_start}`, `selected_date`, `selected_time`, `today={@calendar_today}`, `user_timezone`, `booking_window_days`, `landing_week={CalendarHelpers.landing_week(assigns)}` (the grid then offers a jump back to the week the page landed the booker on), `target={@myself}`, and `heading_tag` to fit your outline. The grid asks for its week itself: while `week_slots` is nil it pushes `load_week` on appearing and on every join. Markup of the theme's own between the week navigation and the days (a day picker for narrow screens, a notice) goes in the `:before_days` slot, which renders inside the grid in every state, so it answers to the grid's own container queries. Tests select times by `data-testid="week-slot"` with `data-date` and `data-time`.
- **`Shared.Components.TimezonePicker`** (`timezone_picker/1`): the timezone dropdown, search box and options. Classes `tz-picker`, `tz-picker__trigger`, `__panel`, `__search-wrapper`, `__search`, `__options` (which also carries your theme's `scroll-y`), `__option`, `__option-content`, `__option-flag`, `__option-text`, `__option-label`, `__option-offset`. The trigger's visible content is your `:trigger` slot; the screen-reader "Your timezone:" prefix is added for you. Render flags with `FlagHelpers.timezone_flag/1`.
- **`Shared.Components.BookingForm`** (`booking_form/1`): the booking step's form (name, email, message, `id="booking-form"`, `data-testid="booking-form"`) with the honeypot, the reCAPTCHA hook and token, the per-field errors and blur validation (see [BookingFlow](#bookingflow)) and, after its inner block (put the guest field there), the reCAPTCHA notice. Pass `form={@form}`, `validation_errors={@validation_errors}` and `target={@myself}`; a theme sets `class`, `contact_class` (a wrapper around name and email), `message_rows` and `labels`, never the structure. `theme_booking_step_parity_test.exs` fails for a shipped theme whose booking step lacks the anti-spam fields.
- **`Shared.Components.MeetingPageBodies`** (`cancel/1`, `reschedule/1`, `cancel_confirmed/1`) and **`Shared.DefaultPages`**: theme-neutral meeting page bodies (classes `manage-page`, `manage-page__*`, styled by `scheduling/shared/components/manage-pages.css` through contract tokens) and the six pages a theme with a `page_shell:` gets, each body inside the shell in `<div class="manage-page manage-page--<page>" data-testid="<theme key>-<page>">`.
- **`Shared.Components.ThemeShell`** (`theme_shell/1`): the page chrome every wrapper renders, in order: the customisation `<style>` block, your background (`:background` slot), then the theme grid with the preview notice, the language switcher, the step and the configured theme extensions. Your wrapper passes `class`, `grid_class`, `grid_style` and `language_class`, plus its theme's `theme_id` (which the extensions receive), and keeps only its background markup.
- **Data utilities** (`TymeslotWeb.Components.MeetingUtils`): `normalize_slot_list/1`
  and `normalize_slot_time/1` normalise time-slot data.
- **`Shared.Components.MeetingDetails`** (`meeting_detail_rows/1`) — the date/time/
  timezone/organizer row layout used by the cancel and reschedule pages.
- **`Shared.Components.AwaitingPayment`** (`awaiting_payment/1`) — the
  `:awaiting_payment` state placeholder for paid embedded bookings.
- **`Shared.VideoSources`** (`video_sources/1`) — `<source>` elements for video
  backgrounds, used inside each wrapper's `<video>` element.
- **`Shared.CustomQuestions.Inputs.Renderer`** plus the per-type input components: the custom-questions field renderers, styled by `scheduling/shared/components/custom-questions.css` (the yes/no tiles and option cards). The theme's `CustomQuestionsComponent` supplies the chrome (card, progress indicator) and delegates rendering and events to the shared engine. The step's events are `answer`, `multi_toggle`, `next_step` and `back_step` (the canonical navigation names every step uses), plus the theme's own `theme:<name>` events, relayed untouched; a step event nothing handles is dropped with a warning (see [Event Communication Pattern](#6-event-communication-pattern)).
- **`TymeslotWeb.Components.LanguageSwitcher`** (`language_switcher/1`) — the locale
  dropdown, rendered by `ThemeShell`.

So the dividing line is: **per-step visual layout is theme-owned; cross-cutting
chrome and field rendering is shared.**

When renaming a selector onto a shared class, keep its specificity: a compound rule such as `.time-slot.selected` becomes `.slot-list__slot.slot-list__slot--selected`, not the bare modifier, or an existing `:hover` rule starts winning.

Icon class names stored in the database (e.g., `meeting_type.icon`) must be sanitized before use as CSS class names to prevent CSS injection. Only sanitize the hero-icon path — emoji icons rendered as text content are auto-escaped by Phoenix:

```heex
<%= if String.starts_with?(@icon, "hero-") do %>
  <.icon name={sanitize_css_class(@icon)} class="your-icon-class" />
<% else %>
  <div class="emoji-icon">{@icon}</div>
<% end %>

defp sanitize_css_class(class_name) do
  class_name
  |> String.replace(~r/[^a-zA-Z0-9\-_]/, "")
  |> String.slice(0, 100)
end
```

### iframe.css

The shell rules every theme needs live in `scheduling/shared/embed.css`: body `flow-root` and `max-content` sizing, the page grid (`.booker-page`) sized to content, the footer hidden, the slot scroll region (`.booker-scroll`) released, and full width in the column layout (`.booker-card`). Mark your page grid, cards and slot region with those three classes. Your theme's `iframe.css` then holds only what is specific to it (hiding or repositioning a background, card corners, the language switcher's embedded position).

Size-driven compaction (compact calendar, smaller badges, form re-layout) is handled by container queries in each component file — the same queries that handle narrow viewports.

### Iframe Auto-Resize

When the scheduling page loads inside an iframe, `iframe_embed.js` continuously measures the page's content height and posts it to the parent on a 50ms loop. The parent iframe element grows AND shrinks to match — so themes should let the body flow to its natural content height in embedded mode (`height: max-content`, no `height: 100%` chains). See `shared/embed.css` for the shared rules and `themes/<theme>/modules/iframe.css` for the per-theme overrides.

The embedder can supply `data-initial-height` (px) on the container as a placeholder height shown before the first measurement lands; `data-min-height` is still accepted as a legacy alias. After the first message, the iframe always matches reported content height.

### Creating Theme CSS

1. **Create theme directory**: `assets/css/scheduling/themes/your-theme/`
2. **Create main theme.css** in the order of [Theme CSS Structure](#theme-css-structure): `../../shared/entry.css`, `./modules/variables.css`, `../../shared/tokens.css`, `./modules/base.css`, `../../shared/embed.css`, then your modules and the `shared/components/*.css` files you use. Every file in `REQUIRED_SHARED_IMPORTS` (`scripts/test_css_tokens.sh`: the entry, `tokens.css`, `embed.css` and the component files for the language switcher, preview and approval notices, the flash toast, booking fields, custom questions, polls and payment pages) must be among them; `mix css.check_tokens` fails, naming the file, for one left out, and for a theme with no `modules/variables.css` or no `theme.css`
3. **Create modular CSS files** in a `modules/` subdirectory — each component file is self-contained
4. **Set container query context** on the primary content container (`container-type: inline-size; container-name: scheduling;`)
5. **No external font imports**: point `--theme-font-family` (and `--theme-font-heading`) at a stack from `shared/fonts.css` (see *Fonts*); a new family is added there, self-hosted, never loaded from a font service
6. **Everything through tokens, nothing hard-coded**: colours live only in `variables.css`; every other file reads tokens. Run `mix css.check_tokens` (part of `mix precommit`).

**Note**: Theme CSS is completely separate from global app styles.

## Theme Requirements

### Must Have
- Theme module implementing `TymeslotWeb.Themes.Core.Behaviour`
- LiveView module that renders without crashing (using the `SchedulingLive` macro)
- Wrapper component for theme layout
- CSS file in `assets/css/scheduling/themes/your-theme/theme.css`, importing every file in `REQUIRED_SHARED_IMPORTS` (`scripts/test_css_tokens.sh`), and `modules/variables.css`; `mix css.check_tokens` fails without them
- `modules/iframe.css` with the theme-specific embed rules (the shared shell is `shared/embed.css`), and the `booker-page`, `booker-card` and `booker-scroll` hook classes on the page grid, cards and slot scroll region
- Container query context (`container-type: inline-size`) on the primary content container
- The 4 core booking flow states: **overview**, **schedule**, **booking**, **confirmation**
- Handling for the conditional **`:questions`** state (custom-questions step, when the meeting type has custom fields) and the transitional **`:awaiting_payment`** state (paid embedded bookings)
- All 5 step components as LiveComponents (the 4 core steps + `custom_questions_component.ex`)
- The booking step renders `Shared.Components.BookingForm.booking_form/1`
- Schedule component with its nav buttons wired to `CalendarNavigation` boundary checks: a weekly strip (mobile) and monthly grid (desktop), as Quill and Rhythm render, or the shared `WeekGrid` (see [A week of slots](#a-week-of-slots)), which wires its own week buttons to them
- Meeting action components (reschedule, cancel, cancel_confirmed), or a `page_shell:` that takes them from `Shared.DefaultPages`

> No per-theme StateMachine module — transitions are owned by the shared
> `StateMachineHelpers`.

### Nice to Have
- Smooth transitions
- Accessibility features

## Using Shared Logic and Helpers

The theme system provides centralized handlers and helpers in `TymeslotWeb.Themes.Shared.*` to ensure consistency and reduce duplication.

> **You normally do not write any of the code in this section by hand.** The
> `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: …, steps: …` macro wires up
> `mount/3`, `handle_params/3`, `render/1`, every `handle_info/2` (step components send
> their events to the LiveView as messages), `handle_async/3` (the week of slots), and the
> language and `navigate_to_step` `handle_event/3` clauses for you (see [Common Patterns](#common-patterns)).
> The subsections below document the underlying helpers the macro calls — read them
> to understand what is happening, or when you need to override a specific extension
> point. A real theme's `live.ex` is its `use SchedulingLive, wrapper: …, steps: …`
> line (with the aliases above it) plus an optional
> `handle_theme_event/3` override.

### LiveHelpers.Mount, StepEntry and Tracking

The macro's `mount/3` calls `LiveHelpers.Mount.mount_scheduling_view/2`, and its `handle_params/3` calls `LiveHelpers.Mount.handle_scheduling_params/2`; both end by entering the step the route names through `SchedulingFlow`. Entering a step is `SchedulingFlow.handle_state_entry/3`, which uses `LiveHelpers.StepEntry` for the schedule, questions and booking steps. Step components bubble their events as `{:step_event, step, event, data}`; the macro hands them to `SchedulingFlow.handle_step_event/4`, and an event it returns `:unhandled` for is dropped with a warning naming the theme, the step and the event (once per name and page view), whatever the step. A theme's own events (`theme:<name>`, below) never reach the flow: they go to `handle_theme_event/3`, from any step.

### EventHandlers

`TymeslotWeb.Themes.Shared.EventHandlers` handles the page-level events outside the booking steps: the language switcher and the timezone search box.

**Key EventHandler Functions**:
- `handle_toggle_language_dropdown/1` - Toggle language selector
- `handle_close_language_dropdown/1` - Close language dropdown
- `handle_change_locale/3` - Change user locale
- `handle_timezone_search/2` - Filter timezone list

### InfoHandlers

`TymeslotWeb.Themes.Shared.InfoHandlers` handles async tasks like availability fetching. The macro's single `handle_info/2` asks `InfoHandlers.route/2` first; a message it returns `:unhandled` for is logged and ignored (`InfoHandlers.handle_unexpected/2`); a theme has no hook for messages.

**Key InfoHandler Functions**:
- `route/2` - Dispatch a mailbox message to its handler, or return `:unhandled`
- `handle_fetch_available_slots/4` - Fetch available time slots for a date
- `handle_load_slots/2` - Load slots for date selection
- `handle_availability_ok/3` - Process successful availability fetch
- `handle_availability_error/3` - Handle availability fetch errors
- `handle_close_dropdown/1` - Close dropdowns after delay

### SchedulingInit

`TymeslotWeb.Themes.Shared.SchedulingInit` provides two initialization helpers:

**`assign_theme_state/1`** — initializes all scheduling state in one call. The scheduling macro calls it at mount (through `LiveHelpers.Mount`), so a theme does not call it itself.

**`assign_base_state/1`** — lower-level; sets only the core socket fields shared across all flows. Use when you need fine-grained control or are not in a full scheduling context.

**Assigns from `assign_theme_state/1`** (superset of `assign_base_state/1`):
- `:duration`, `:meeting_type` - nil until selected
- `:month_availability_map`, `:availability_status`, `:availability_task`, `:availability_task_ref`
- `:week_slots`, `:week_slots_start`, `:week_slots_loading`, `:week_slots_error` - a week view's week of slots: nil until the view asks for one, the week last asked for, and the fetch's state (see [A week of slots](#a-week-of-slots))
- `:form`, `:touched_fields`, `:validation_errors`, `:saving` - booking form state
- `:client_ip`, `:submission_token`, `:meeting_types`
- Plus all assigns from `assign_base_state/1` below

`:theme_id` is assigned by the dispatcher before the theme mounts.

The calendar window is not set here. `LiveHelpers.Mount` sets `:current_year`, `:current_month`, `:current_week_start`, `:calendar_today` (the date the calendar opened on) and `:calendar_landing` (where the page itself last left the calendar, read by `CalendarHelpers.untouched?/1`) with `CalendarHelpers.anchor_on_today/1` once `:user_timezone` is known, so the calendar opens on today in the visitor's timezone. Entering the schedule step reopens it with `CalendarHelpers.anchor_on_selection/1`: on the chosen day's month and week when there is one, whether linked with `?date=YYYY-MM-DD` or chosen on an earlier visit, otherwise on today. A chosen day before today or past the booking window is dropped there, and `NextAvailable` lands the booker on the first free day instead. Anything that positions the calendar on a date uses `CalendarHelpers.anchor_on/2`; do not assign `:current_year`, `:current_month` or `:current_week_start` by hand. A timezone picked in the picker (`NextAvailable.follow_timezone_change/1`) moves it only while it is still where the page left it: on today with no day chosen, or on the day `NextAvailable` landed on, which is dropped and picked again for the new zone. A selected day that is outside the booking window in the new zone (already past there) is dropped and picked again too, whoever chose it. A still-bookable day the booker clicked or linked with `?date=`, or a month or week they navigated to, stays. The month's availability, which is worked out per day in the visitor's timezone, is always refetched.

**Assigns from `assign_base_state/1`**:
- `:current_state` - Current step in the flow
- `:username_context`, `:organizer_profile`, `:organizer_user_id`
- `:selected_duration`, `:selected_date`, `:selected_time`
- `:available_slots`, `:loading_slots`, `:calendar_error`
- `:timezone_dropdown_open`, `:timezone_search`
- `:reschedule_meeting_uid`, `:is_rescheduling`, `:meeting_uid`
- `:name`, `:email`, `:submitting`, `:submission_processed`

### A week of slots

A theme with a week view renders `Shared.Components.WeekGrid` on its schedule step and gets the rest from the flow (`TymeslotWeb.Live.Scheduling.WeekSlots`). Nothing fetches a week until the grid asks with the canonical `load_week` event, which it sends itself while `:week_slots` is nil; a theme without a week view never sends it, so its page never fetches a week. From then on the flow keeps the week current: `prev_week`/`next_week`, a day the page lands the booker on in another week, a timezone change, a calendar sync and every arrival at the schedule step fetch the week on screen (`:current_week_start`) again, through `Offer.slots_for_range/4`, whose days are exactly what `Offer.slots_for_date/3` offers. The fetch is a `start_async/3` task named `{:week_slots, week_start}`: the flow cancels the one in flight before starting another, and applies a result only for the week last asked for. The dispatcher forwards `handle_async/3` to the theme as it does `handle_info/2`, and the macro generates the theme's clause, so a theme writes no callback for any of it. One click on a time sends `select_slot` with the day and the time: the flow selects both together (where `select_date` clears the time), loads that day's slots into `:available_slots` as a day pick does, and ignores a pair the loaded week does not offer, so the booking step and a reschedule see what they see after a day and a time click. From a week other than the one `NextAvailable` landed the booker on, the grid offers `first_available_week`, which moves the calendar back there (`CalendarHelpers.return_to_landing/1`).

### BookingFlow

`TymeslotWeb.Themes.Shared.BookingFlow` handles form validation and submission; field-touched state lives in `TymeslotWeb.Live.Scheduling.OrganizerHelpers`. `SchedulingFlow` routes the booking step's events to them, so a theme never calls them itself:

```elixir
# In SchedulingFlow
defp booking_event(socket, :validate, data),
  do: BookingFlow.handle_form_validation(socket, data)

defp booking_event(socket, :field_blur, field),
  do: {:noreply, OrganizerHelpers.mark_field_touched(socket, field)}

defp booking_event(socket, :submit, data),
  do: BookingFlow.submit_booking(socket, data, &transition_to/3)
```

**Key BookingFlow Functions**:
- `handle_form_validation/2` - Validate form fields in real-time
- `submit_booking/3` - Submit booking and transition to confirmation
- Both functions handle spam prevention, rate limiting, and error handling automatically

**Per-field inline errors**: `Shared.Components.BookingForm` renders its name, email and message inputs with per-field errors (`FormValidationHelpers.field_errors/2`, the pattern the auth and contact forms use), so a theme writes none of this for them. An input a theme adds to the booking step itself follows the same pattern: it passes its errors explicitly, and `phx-debounce="blur"` alongside `phx-blur="field_blur"`. The debounce suppresses the `phx-change` event until the field loses focus, and the blur event triggers per-field validation; without it, every keystroke fires a server round-trip:

```heex
<.input
  field={f[:name]}
  errors={FormValidationHelpers.field_errors(@validation_errors, :name)}
  phx-debounce="blur"
  phx-blur="field_blur"
  phx-value-field="name"
  phx-target={@myself}
/>
```

Errors only appear for fields the user has blurred (`touched_fields` MapSet), and clear automatically when the user corrects the input (validation returns `{:ok, ...}` → `validation_errors` becomes `%{}`).

### LocalizationHelpers

Always use `TymeslotWeb.Themes.Shared.LocalizationHelpers` for formatting dates, times, and durations to ensure they respect the user's locale:

```elixir
alias TymeslotWeb.Themes.Shared.LocalizationHelpers

# Result: "Wednesday, 15 March 2024 at 14:30 EST"
LocalizationHelpers.format_booking_datetime(@date, @time, @timezone)

# Result: "30 minutes" or "1 hour"
LocalizationHelpers.format_duration("30min")
```

### PathHandlers

Use `TymeslotWeb.Themes.Shared.PathHandlers` for internal navigation to preserve locale and theme settings:

```elixir
# Build a path that includes ?locale=... and ?theme=...
back_path = PathHandlers.build_path_with_locale(socket, socket.assigns.locale)
```

## Theme Customization Spec

Each theme declares what organisers can customise in a spec module that `use`s `Tymeslot.ThemeCustomizations.Spec`, named by `customization_spec:` in its Catalog entry. The spec is the only place the theme's customisation rules live:

| Callback | Purpose |
|---|---|
| `option_groups/0` | The option groups, in dashboard order: descriptors naming their module, e.g. `%{key: :palette, module: Options.Palette, schemes: [...]}` and `%{key: :background, module: Options.Background, kinds: [:gradient, :color, :image, :video], gradients: [...], images: [...], videos: [...]}` |
| `defaults/0` | The theme's defaults: what a customisation reads as for every setting it does not store (a new row, an organiser with none, a group added to the spec later), and what a group falls back to when its stored settings stop being accepted |
| `changeset/2` | Generated by `use`: every group's `changeset/3`, in order, rejecting any option or background kind the theme does not offer |
| `tokens/2` | Generated by `use` (`Specs.tokens/3`): every group's `tokens/4`, folded in declaration order, plus every group's media; stored settings plus per-page-view overrides to `%Tymeslot.ThemeCustomizations.Tokens{}` |
| `asset_fields/0` | Generated by `use`: every group's `asset_fields/1`; the settings that hold uploaded files, for upload handling and file clean-up. Each field belongs to the option group that declares it in `asset_fields/1`; an upload into it saves that group's `upload_changes/3`, limited to the group's own settings. At most one `:video` field per theme: the transcoder tracks one video per customisation row. |
| `onboarding_choices/0` (optional) | What the onboarding wizard offers: `%{group:, field:, setting:, choices: [%{value:, name:, swatch:}]}`, or `nil` to show no choice row. `use Spec` generates it from the palette group's `schemes:` (in that order, swatch = the scheme's primary); override it to offer something else |

A spec writes `option_groups/0` and `defaults/0`, and composes the shared groups (`Options.Palette`, `Options.Background` and those of [Shared option groups](#shared-option-groups)) rather than restating their rules; `QuillSpec` and `RhythmSpec` are the reference for the palette and background, the showcase theme's spec for the rest. A group is any module implementing `Tymeslot.ThemeCustomizations.OptionGroup` (`types/0`, `changeset/3`, `changes/3`, optionally `tokens/4`, `asset_fields/1`, `upload_changes/3` and `media/2`), handed its own descriptor on every call; shared code never branches on which group it is, so a theme's own option is one module listed in its spec. An option module that stores files implements `asset_fields/1` (the fields and their kinds) and `upload_changes/3` (what an upload into one of them saves, string-keyed, only the group's own settings); one that renders something implements `media/2`. `Specs.group(spec, module)` returns a spec's group for a module. `Spec` is only the contract, so `use Spec` costs a theme no compile-time coupling (it only checks, once the spec has compiled, that no two groups declare the same setting or share a `key:`, and fails the compile naming them); the questions asked of a spec (`group/2`, `for_theme/1`, ...) live in `Specs`. Keep it that way: a helper that calls another module belongs in `Specs`.

The onboarding wizard's colour row lists `onboarding_choices/0` in its order and saves a pick with `apply_option(profile_id, theme_id, group, %{"field" => field, "value" => value})`; a theme without a palette gets no row.

Each group lists the presets the theme offers: a palette group's `schemes:`, in the theme's presentation order (the onboarding wizard follows it; the dashboard sorts schemes by id), and a background group's `gradients:`, `images:` and `videos:`, in picker order (a missing list offers none of that kind). Writes are validated against the group's lists and the dashboard shows only them, so a preset added to the catalogue reaches a theme only once its spec lists it. `Options.Palette.schemes/1` and `Options.Background.presets/2` return a group's presets in order. Rendering resolves a stored preset from the whole catalogue.

A theme's settings are stored in the `settings` map of its `theme_customizations` row, not in columns of their own, so a theme with a different option set needs no migration. Each setting belongs to exactly one group: a spec two of whose groups declare the same setting, or share a `key:`, does not compile. The keys are those of the spec's option groups (`Specs.setting_types/1`: each group module's `types/0`); a key outside them is dropped on the next save, and an empty setting is left out rather than stored as `null`. Every read goes through `Specs.settings/2` (the booking page through `ThemeCustomizations.tokens/3`, the dashboard through `initialize_customization/2`, and the schema changeset every save starts from): for each group, its stored settings over the spec's defaults, kept when the group's own `changeset/3` accepts them and otherwise the group's defaults alone. So a value a group no longer accepts (a preset dropped from its list, a kind the theme stopped offering) costs that group its choice and never blocks a save of another group, and a group added to a spec after a row was saved starts from its defaults. A group that falls back drops the upload its stale settings named, and the next save deletes the file. `changeset/2` receives a schemaless changeset over the spec's types, holding those read settings as its data and a save's changes as changes, so it validates with plain `cast/3`, `get_field/2` and `add_error/3`; its errors reach the row's changeset under the setting's name. Writes pass the settings flat, beside the columns (`%{"theme_id" => "1", "background_type" => "video"}`), and templates never read them (they read `@theme_tokens`); dashboard panels read `customization.settings`, already read through `Specs.settings/2`. `video_processing` stays a column: the transcoding worker writes it directly.

Colours are validated by `Tymeslot.Utils.Colour.cast_hex/1`: `#RGB` or `#RRGGBB`, stored as lower-case `#rrggbb`.

A colour scheme (`Tymeslot.ThemeCustomizations.Presets.ColourSchemes`) is `%{name:, mode: :light | :dark, colors:, dark_colors:}`: `colors` is the set for `mode`, and a light scheme may carry `dark_colors`, its counterpart for a theme that follows the visitor's OS (a dark scheme has none). The eight schemes Quill and Rhythm offer are dark. The three tones (`neutral`, `cool`, `warm`) are light, each with `dark_colors`, and share one primary family, which an accent group replaces. A custom seed is derived in the same shape by `PaletteDerivation.derive_palette(seed, mode)` (`:dark` by default); a light derivation's `dark_colors` is the dark derivation of the same seed.

A palette group fills `dark_vars` only when it says `follow_os: true` and the resolved scheme is a light one with `dark_colors`; otherwise the page shows the scheme's own colours whatever the visitor's OS prefers. `seed_mode: :light` makes a custom seed derive a light palette (the default is `:dark`). A theme that follows the OS also declares `color-scheme: light dark` and its non-palette dark roles in its own CSS: `ThemeStyle` writes custom properties only. A palette that offers no preset schemes (`schemes: []`) stores its seed alone, with no scheme name beside it; the seed is the palette.

A spec's `tokens/2` turns the saved settings, plus per-request overrides, into a `%Tokens{}`: `vars` (the palette colours and contrast pairs as `--theme-*` custom properties, the palette's background as `--theme-canvas`, and the background option as `--theme-background`), `dark_vars` (the same for a visitor whose OS is in dark mode, written inside `@media (prefers-color-scheme: dark)`; empty for Quill and Rhythm), and `media`, a map of what the option groups resolve for the page to render, each group adding its own key through its optional `media/2` callback (`Specs.media/2` merges them; the background's is `:background`, a descriptor `%{kind: :gradient | :color | :image | :video, ...}` the theme wrapper renders). `use Spec` generates it as `Specs.tokens/3`, which folds each group's optional `tokens/4` callback over the spec's `option_groups/0` in declaration order: a group receives the `vars` and `dark_vars` the groups before it produced and returns what the next one receives. The palette (`Options.Palette.tokens/4`) adds its colours and contrast pairs, the background after it adds `--theme-background` (the canvas behind an image or video, so it is declared after the palette), and a group without `tokens/4` changes nothing; `Specs.media/2` then adds the media. Declaration order is therefore meaningful: a group that reads or rewrites another group's variables comes after it. Quill and Rhythm use it as generated. A spec with tokens of its own overrides `tokens/2` and starts from `Specs.tokens(__MODULE__, settings, overrides)`. Callers go through `ThemeCustomizations.tokens/3`, which falls back to the theme's defaults when nothing is saved.

A group added to `option_groups/0` therefore reaches the page without further wiring. A group of a theme's own that renders something (a logo, a cover image) returns it from `media/2` under a key of its own, already sanitised (`Validation.sanitize_path/1` for an uploaded file), and the theme's templates read `@theme_tokens.media[:key]`; a key is absent when nothing resolved.

A per-embed `?primary-color=` arrives in `tokens/2` as `%{primary_color: hex}`; a spec with a palette must honour it.

The contrast pairs (`--theme-on-primary`, `--theme-primary-solid`, `--theme-primary-solid-hover`, `--theme-on-accent`, `--theme-accent-solid`) come from `Tymeslot.ThemeCustomizations.ContrastTokens`: the ink is white or the palette's darker of `background` and `text`, whichever reads better, and the solid surface moves only as far as it must for 4.5:1. The rule works on light and dark palettes alike. `ContrastTokens.derive/1` never adjusts `--theme-primary` itself. Whether the primary reads as text on the card is `ContrastTokens.fit_text(colour, ground, min_ratio \\ 4.5)`: the colour's lightness walks away from the ground (towards white on a dark one, towards black on a light one) until the pair clears the ratio, and a colour that already does is returned unchanged. A light seed derivation fits its primary to its surface this way, and its secondary and accent to its ground at 3:1; a light preset scheme's own primary has to read on its card as it stands.

Every option change goes through `ThemeCustomizations.apply_option(profile_id, theme_id, option_key, %{"field" => ..., "value" => ...})`, which finds the group in the spec's `option_groups/0`, asks the group's module for the changes (`group.module.changes(field, value, group)`; `:error` refuses the choice), and saves them through the spec changeset. Only the change is saved; the rest of the row is what `Specs.settings/2` reads.

The dashboard's customisation panel (`ThemeCustomizationComponent`) renders one panel per `option_groups/0` entry: `ThemeCustomization.Panels.for_group/2` returns the theme's own panel for the group's module (its `option_panels:`), else the built-in panel of a shared group (`PalettePanel`, `BackgroundPanel`, whose tabs show the group's `kinds`, or one of those in [Shared option groups](#shared-option-groups)), and `Components.option_panel/1` renders it. Every option write is the `theme:set_option` event (`option`, `field`, `choice`, targeted at `@myself`), which calls `apply_option/4` with `%{"field" => field, "value" => choice}`. The wire param is named `choice`, not `value`: LiveView's client serialisation reads a button's native `value` IDL property and would otherwise overwrite `phx-value-value` with the empty string on every click. A panel is a function component module that `use`s `ThemeCustomization.Panel`: it defines `render/1` and overrides, where it needs to, the defaults `use` supplies for `ui/3` (what it shows between writes, such as the open background tab, the palette's seed picker or the custom-colour disclosure, on load and after each save of its group), `handle_ui/5` (any other `theme:*` event carrying `phx-value-option`, answered with new state, a write, or `:ignore`) and `telemetry/3` (the event name and rate-limit label of a write). The component keeps that state per group and spreads it into the panel's assigns; it has no clause for any particular panel. Every field in the spec's `asset_fields/0` gets an upload input of its own, named after it (`@uploads.background_image_path`), declared by `AssetUploads`. An upload form, the background pickers' or a panel of a theme's own, sends `upload_asset` on change and submit with a hidden `asset_field` input naming its field; the component saves it through `attach_asset/4`. A new option type of one theme's own needs an `OptionGroup` module and a panel module, named in the theme's `option_panels:`; neither touches a shared file. A group several themes share lives under `theme_customizations/options/` with its panel beside `PalettePanel`, in the built-in map of `Panels`. The upload form of every image field, the background's included, is `Pickers.ImageUpload.image_upload/1` (`id`, `field`, `uploads`, `myself`).

### Shared option groups

Besides the palette and the background, `lib/tymeslot/theme_customizations/options/` holds seven shared groups the lighter themes are built from: `colour_mode`, `accent`, `font`, `radius`, `density`, `logo` and `cover`. A spec declares each like any other group, with its configuration in the descriptor. Each emits its variables through `tokens/4`, which the generated `tokens/2` folds in declaration order (above), so their order in `option_groups/0` matters. The canonical order is `palette`, `colour_mode`, `accent`, `font`, `radius`, `density`, `logo`, `cover`, `background`. A customisation saved before the theme offered a group reads the spec's `defaults/0` for it (`Specs.settings/2`); a group's `default:` is also what it falls back to for a missing or unknown stored value.

| Group | Descriptor | Setting | Emits |
|---|---|---|---|
| `Options.ColourMode` | `%{key: :colour_mode, module: Options.ColourMode, default: "auto"}`, right after a palette group with `follow_os: true` and `seed_mode: :light` that lists light schemes only (a dark seed or scheme has no light set to choose; `SpecTest` checks it) | `colour_mode`: `light`, `dark` or `auto` | chooses between the palette's sets: `light` keeps `vars` and drops `dark_vars`, `dark` puts the dark set over `vars` and drops `dark_vars`, `auto` keeps both (the dark set then sits inside `@media (prefers-color-scheme: dark)`); and `--theme-color-scheme` (`light`, `dark`, `light dark`) in `vars`, which the theme's CSS reads as `color-scheme: var(--theme-color-scheme)` |
| `Options.Accent` | `%{key: :accent, module: Options.Accent, presets: [ids], default: id}`, after the palette | `accent`: an id from `presets:` (the catalogue is `Presets.Accents`) or a custom `#rrggbb` | the primary family (`--theme-primary`, `--theme-primary-hover`, `--theme-on-primary`, `--theme-primary-solid`, `--theme-primary-solid-hover`) in `vars`, and in `dark_vars` when the palette produced any; `--theme-primary` is fitted as text on that set's card (`ContrastTokens.fit_text/3`), its surface or, where that is translucent, its canvas. A `?primary-color=` override wins over the stored accent and is fitted the same way |
| `Options.Font` | `%{key: :font, module: Options.Font, presets: [ids], default: id}` | `font`: an id from `presets:` (the catalogue is `Presets.Fonts`: `system`, `inter`, `plex`, `classic`, `literary`, `editorial`, `quiet`) | `--theme-font-family: var(--font-stack-<id>)` and `--theme-font-heading: var(--font-heading-<id>)` in `vars`, never a family name; the stacks are defined for every id in `scheduling/shared/fonts.css` |
| `Options.Radius` | `%{key: :radius, module: Options.Radius, default: "soft"}` | `radius`: `sharp`, `soft` or `round` | the radius roles `--radius-control` and `--radius-card` in `vars`: `2px`/`4px`, `8px`/`12px`, `999px`/`20px` |
| `Options.Density` | `%{key: :density, module: Options.Density, default: "comfortable"}` | `density`: `comfortable` or `compact` | `--density` in `vars`: `1` or `0.75`, the factor the theme's spacing multiplies |
| `Options.Logo` | `%{key: :logo, module: Options.Logo}`, no configuration | `logo_path`: an uploaded image, which arrives only through an upload into that field (replacing and deleting the previous one); the one choice is removing it (`theme:set_option` with field `logo_path` and an empty choice) | no variables; `media[:logo]` is `%{src: url}`, sanitised as an uploaded background's URL is, and absent without a logo |
| `Options.Cover` | `%{key: :cover, module: Options.Cover, presets: [ids], default: id}` | `cover_value`: an id from `presets:` (the catalogue is `Presets.Covers`: four reuse the background images under the same ids and names, three are covers of their own) or `"custom"`, and `cover_path`: an uploaded image. Choosing a preset drops an uploaded cover and deletes its file; an upload into `cover_path` makes it the custom cover | no variables; `media[:cover]` is `%{src: url, preset: id}` for a preset or `%{src: url, preset: nil}` for an upload, the descriptor's `default:` while nothing is stored, and absent when the stored value resolves to nothing |

Each has a built-in dashboard panel beside `PalettePanel` in `live/dashboard/theme_settings/theme_customization/`, in the built-in map of `Panels`, so a theme that declares one names nothing in `option_panels:`: `ColourModePanel` (the three modes), `AccentPanel` (the group's presets and a custom colour), `FontPanel` (the group's fonts by name, each in its own face: the dashboard's `app.css` imports `shared/fonts.css`), `RadiusPanel`, `DensityPanel`, `LogoPanel` (the stored logo, an upload and its removal) and `CoverPanel` (the group's covers and an upload). Which of them a shipped theme offers is its spec's `option_groups/0`; the showcase theme declares them all (see [Test-only themes](#test-only-themes)).

### A theme with options of its own

Check the shared parts first. The seven [shared option groups](#shared-option-groups), each with its built-in panel, offer colour mode, accent, font (the stacks of [Fonts](#fonts)), radius, density, a logo and a cover image; a week view is the shared `WeekGrid` and the flow's week of slots ([A week of slots](#a-week-of-slots)); the organiser's headline and bio are `ProfileIntro` ([Shared Components](#shared-components)). A group of your own is for what none of them offers.

A theme is not limited to the shared palette and background, and adding an option of its own changes no shared module. The fixture theme under `test/support/fixture_theme/` (registered in the test build only, see [Test-only themes](#test-only-themes) below) is the smallest complete example: a light palette with no preset schemes, no background, and an `Emblem` group with a choice, an upload and a media entry, shown in the dashboard by a panel of its own. A group of your own is four pieces:

1. **A module implementing `Tymeslot.ThemeCustomizations.OptionGroup`** (`emblem.ex`), with the callbacks described above: `types/0`, `changeset/3` (reading its configuration from the group descriptor), `changes/3` (`:error` for a field it does not have) and, only when it needs them, `asset_fields/1`, `upload_changes/3` and `media/2`. Every group of every theme writes into the one `settings` map of a customisation row, so prefix the setting names with the theme's key (`fixture_emblem_shape`, `fixture_emblem_path`); a name another group of the spec already stores fails the spec's compile.
2. **A descriptor in the spec's `option_groups/0`** (`fixture_theme_spec.ex`): `%{key: :emblem, module: Emblem, choices: ["round", "square"]}`. `key` names the group in `theme:set_option` and `apply_option/4`; every other key is the group's own configuration, handed back to each callback as `group`. `use Tymeslot.ThemeCustomizations.Spec` folds the group into the generated `changeset/2` and `asset_fields/0`, `Specs.setting_types/1` picks up its `types/0`, and `Specs.media/2` its `media/2`, so templates read `@theme_tokens.media[:emblem]` with no further wiring.
3. **Its custom properties, if it has any.** A group that sets variables implements `tokens/4`, taking and returning `%{vars:, dark_vars:}`, and the generated `tokens/2` picks it up in declaration order (after any shared group whose variables it reads). A spec may instead override `tokens/2`, start from `Specs.tokens(__MODULE__, settings, overrides)` and merge its variables in, which is what the fixture does with `Emblem.vars/2` (`--fixture-emblem-radius`, a name of the theme's own; use a contract token's name only to set that token), finding its descriptor with `Specs.group(__MODULE__, Emblem)`.
4. **A dashboard panel** (`emblem_panel.ex`): a function component module that `use`s `TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel` and defines `render/1`, registered on the theme with `use TymeslotWeb.Themes.Core.Theme, option_panels: %{Emblem => EmblemPanel}` (see the dashboard paragraph above for the assigns, the `theme:set_option` write and the optional UI-state callbacks; the fixture keeps no UI state). An upload is a form sending `upload_asset` with a hidden `asset_field` input and `<.live_file_input upload={@uploads[field]} />`. A group with no panel of the theme's own gets a built-in one only if it is a shared group (`Options.Palette`, `Options.Background`, `Options.Logo`, `Options.Cover`, `Options.ColourMode`, `Options.Accent`, `Options.Font`, `Options.Radius`, `Options.Density`); for any other group `Panels.for_group/2` raises, naming the fix.

A theme's own booking-page behaviour is an event of its own, not a new canonical one: a step template sends `phx-click="theme:<name>"` with `phx-target={@myself}`, `Shared.StepEvents` forwards it, and the theme's `live.ex` handles `<name>` in a `handle_theme_event/3` clause, followed by a catch-all clause calling `super/3` (see [Event Communication Pattern](#6-event-communication-pattern); the fixture's overview step sends `theme:ping`).

`test/tymeslot_web/themes/theme_openness_test.exs` drives each of these through the real routes, and fails if any file under `lib/` or the non-test config names the fixture or the showcase theme.

### Test-only themes

`config :tymeslot, :extra_themes` in `config/test.exs` registers themes that exist only in the test build: each entry is a set of catalogue facts plus the theme's `:module`, which `Catalog` and `Registry` read with `Application.compile_env/3` (default `[]`). Never set `:extra_themes` in any other config. The test build has two such themes and one test-only spec with no theme:

- **The fixture** (id `"99"`, `test/support/fixture_theme/`): the worked example of a theme of its own (a light palette stored as a seed alone, following the OS, and the `Emblem` group above), and the smallest theme built on the shared parts. Its `page_shell` gives it the default meeting, poll and payment pages; its overview renders `ProfileIntro` and sends `theme:ping`; its schedule step renders the shared `WeekGrid` and its booking step `BookingForm`. So the week of slots, booking and rescheduling through it, and the organiser's headline and bio are exercised through a real booking page (`week_slots_flow_test.exs`, `week_grid_journey_test.exs`, `profile_intro_journey_test.exs`).
- **The showcase** (id `"97"`, `test/support/showcase_theme/`): declares all seven [shared option groups](#shared-option-groups) in the canonical order (`palette` over the light tones following the OS, `colour_mode`, `accent`, `font`, `radius`, `density`, `logo`, `cover`, then Quill's `background`), and borrows the fixture's live view (its steps, and its wrapper, which renders the logo and cover media when a spec resolves them) and its `page_shell`. Its dashboard panels, uploads and booking-page tokens and media are proved through the real routes, each group alone and all of them together (`showcase_theme_test.exs`).
- **`Tymeslot.Test.ThemeCustomizations.GroupsSpec`** (`test/support/theme_customizations/groups_spec.ex`): a spec registered with no theme, declaring the palette over the tones and the five groups that emit variables (`colour_mode`, `accent`, `font`, `radius`, `density`) in the canonical order, for the tests of `Specs` and of the contrast rules that need no page (`groups_spec_test.exs`, `accent_contrast_test.exs`).

The default pages' test ids carry each theme's own key (`showcase-payment-processing`), which is what the payment return suite tells themes apart by. Both themes' `ThemeTestMatrix` entries say `fixture: true`, so the flow suites and the e2e embed matrix (`all/0`) skip them while the contract suites (`registered_ids/0`) and the production checklist (`Catalog.valid_ids/0`) cover them. SaaS's test build inherits the entries and compiles Core's `test/support`, so both exist there too.

## Meeting Management Integration

`use TymeslotWeb.Themes.Core.Theme` generates `render_meeting_action/2`, which dispatches each action to the theme's own module:
- `:reschedule` to `Meeting.Reschedule`
- `:cancel` to `Meeting.Cancel`
- `:cancel_confirmed` to `Meeting.CancelConfirmed`

These modules reside in `lib/tymeslot_web/themes/[theme_name]/meeting/`, each with a `render/1`. A theme with a `page_shell:` writes none of them: its meeting pages are `Shared.DefaultPages`, the shared `MeetingPageBodies` inside its shell.

## Common Patterns

### Modular LiveView Architecture

Modern themes follow a layered architecture that keeps the LiveView thin and maintainable:

#### 1. **SchedulingLive Macro**

All common LiveView callbacks are provided by the shared macro — no per-theme boilerplate needed:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Live do
  @moduledoc """
  Aurora theme scheduling LiveView: the shared booking flow in Aurora's
  wrapper and step components.
  """

  alias TymeslotWeb.Themes.Aurora.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Aurora.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.aurora_wrapper/1,
    steps: %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      questions: CustomQuestionsComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
end
```

The macro generates `mount/3`, `handle_params/3`, `handle_info/2`, `handle_event/3`, `handle_async/3` and `render/1`. `render/1` puts the current step's component inside your wrapper, and also handles the organiser-not-ready message, the `:awaiting_payment` screen and an unknown state. The aliases must come before `use`.

State machine logic (initial state, transition validation, navigation guards) lives in the shared `StateMachineHelpers` module — no per-theme StateMachine module is required.

#### 2. **Legacy: Per-Theme StateMachine Module**

> **Deprecated** — do not create new per-theme `state_machine.ex` files. The shared `StateMachineHelpers` covers all standard transitions. If you need custom transition validation, change `StateMachineHelpers`, which every theme shares, instead.

For historical reference, the shared module handles:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.StateMachine do
  @moduledoc """
  State machine for Aurora theme scheduling flow.
  """

  @doc "Determines initial state from Phoenix live_action"
  def determine_initial_state(live_action) do
    case live_action do
      :index -> :overview
      :overview -> :overview
      :schedule -> :schedule
      :booking -> :booking
      :confirmation -> :confirmation
      _other -> :overview
    end
  end

  @doc "Validates state transitions"
  def validate_state_transition(socket, current_state, next_state) do
    case {current_state, next_state} do
      {:overview, :schedule} -> validate_overview_complete(socket)
      {:schedule, :booking} -> validate_schedule_complete(socket)
      {:booking, :confirmation} -> {:ok, socket}
      _ -> {:error, "Invalid state transition"}
    end
  end

  @doc "Checks if navigation to a step is allowed"
  def can_navigate_to_step?(socket, target_state, states) do
    # Only allow navigation to previous or current steps; `states` is
    # `states_for(meeting_type)`, so step numbers follow the meeting type's flow
    with %{step: current_step} <- states[socket.assigns[:current_state]],
         %{step: target_step} <- states[target_state] do
      target_step <= current_step
    else
      _other -> false
    end
  end

  defp validate_overview_complete(socket) do
    if socket.assigns[:duration] && socket.assigns[:meeting_type] do
      {:ok, socket}
    else
      {:error, "Please select a meeting duration"}
    end
  end

  defp validate_schedule_complete(socket) do
    cond do
      not socket.assigns[:selected_date] ->
        {:error, "Please select a date"}
      not socket.assigns[:selected_time] ->
        {:error, "Please select a time"}
      true ->
        {:ok, socket}
    end
  end

  defp get_step_number(state) do
    case state do
      :overview -> 1
      :schedule -> 2
      :booking -> 3
      :confirmation -> 4
      _ -> 0
    end
  end
end
```

#### 3. **Wrapper Component**

The wrapper provides the theme's background and class names; the shared `ThemeShell` renders the rest of the page chrome (customisation styles, preview notice, language switcher, theme extensions) around them:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Wrapper do
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  import TymeslotWeb.Themes.Shared.Customization.Helpers, only: [prepare_wrapper_assigns: 1]
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]

  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  attr :owner_preview, :boolean, default: false
  attr :demo_mode, :boolean
  slot :inner_block, required: true

  def aurora_wrapper(assigns) do
    # Derives @background, @has_video_background, @show_language_switcher
    assigns = assigns |> prepare_wrapper_assigns() |> assign(:theme_id, theme_id())

    ~H"""
    <ThemeShell.theme_shell
      class="aurora-theme-wrapper theme-3"
      grid_class="aurora-content theme-grid"
      grid_style={ThemeStyle.inline_background(@background)}
      language_class="aurora-language-switcher"
      theme_id={@theme_id}
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@show_language_switcher}
      owner_preview={@owner_preview}
      organizer_user_id={@organizer_user_id}
      should_show_branding={@should_show_branding}
      {Map.take(assigns, [:demo_mode])}
    >
      <:background :if={@has_video_background}>
        <div class="video-background">
          <video autoplay muted loop playsinline preload="metadata" poster={@background.poster}>
            <.video_sources sources={@background.sources} />
          </video>
        </div>
      </:background>
      {render_slot(@inner_block)}
    </ThemeShell.theme_shell>
    """
  end

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:aurora)
    id
  end
end
```

Notes on the real pattern (matching Quill and Rhythm):
- `ThemeShell` renders the language switcher (`TymeslotWeb.Components.LanguageSwitcher`),
  which takes no theme argument: it emits the theme-neutral classes `lang-switcher`,
  `lang-switcher__button`, `__panel`, `__item` and `__item--active`, which the theme's
  own CSS styles. Your wrapper only names the class of its container (`language_class`).
- `theme_tokens` arrives as an assign; the shell renders it with `ThemeStyle.theme_style/1`.
  Never write your own `<style>` block for customisation values.
- `organizer_user_id` is an **integer**.
- `ThemeShell` renders the theme extensions (`Layouts.render_theme_extensions/1`) in the
  grid's footer row, handing them `theme_id`, `organizer_user_id`,
  `should_show_branding`, and `demo_mode` when the page assigned one. Do not hand-roll
  a "Powered by Tymeslot" footer.
- Pass `demo_mode` on with `{Map.take(assigns, [:demo_mode])}` rather than as
  `demo_mode={@demo_mode}`, so the extensions see it only when the page set it.

#### 4. **Step Components**

Each step is a separate LiveComponent:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Components.OverviewComponent do
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="overview-step">
      <h1>Select Meeting Duration</h1>
      <div class="meeting-types">
        <%= for mt <- @meeting_types do %>
          <button
            phx-click="select_duration"
            phx-value-duration={mt.duration}
            phx-target={@myself}
            class={duration_button_class(mt.duration, @duration)}
          >
            <%= format_duration(mt.duration) %>
          </button>
        <% end %>
      </div>
    </div>
    """
  end
end
```

**What a step may read.** Each step component receives the scheduling LiveView's assigns (`SchedulingPage` passes them through, `StepEvents.update/2` copies them in). A step relies only on those below; every other assign the LiveView holds belongs to the flow and may change. "mount" means the page holds the assign from the moment it mounts, possibly as a default (`nil`, `[]`, `""`) until the step that fills it; read an "optional" one as `assigns[:name]`. An assign a theme sets itself (in `handle_theme_event/3`) is absent until then, so it is read as `assigns[:name]` too. `step_assigns_doc_test.exs` holds every "mount" row to the mounted page of every registered theme.

<!-- step-assigns:start -->
| Assign | Read on | Present | Holds |
|---|---|---|---|
| `locale` | every step | mount | the page's locale (`data-locale`, date and time formatting) |
| `current_state` | every step | mount | the step on screen (`:overview`, `:schedule`, `:questions`, `:booking`, `:confirmation`) |
| `theme_tokens` | every step | mount | the `%Tokens{}` of the organiser's customisation; templates render from its `media` |
| `organizer_profile` | overview, schedule, booking, confirmation | mount | the organiser's profile: name, avatar, greeting, `headline`, `bio` |
| `username_context` | every step | mount | the organiser's username, for paths |
| `meeting_types` | overview | mount | the organiser's active meeting types |
| `host_currency` | overview, schedule, booking | mount | the currency the organiser's paid meeting types are priced in, for `BookingText.price_label/3`; `nil` while none is paid |
| `selected_duration` | overview, schedule, booking | mount | the chosen meeting type's duration slug; `nil` until one is chosen |
| `duration` | schedule, questions, booking, confirmation | mount | the duration slug the schedule step was entered with (`"30-minutes"`), `nil` before; never print it: show the length with `BookingText.duration_label/1`, or take the number from `Offer.duration_minutes(@meeting_type, @duration)` |
| `meeting_type` | schedule, booking, confirmation | mount | the chosen meeting type; `nil` until a step resolves one |
| `user_timezone` | schedule, booking, confirmation | mount | the booker's timezone |
| `timezone_dropdown_open` | schedule | mount | whether the timezone picker is open |
| `timezone_search` | schedule | mount | the timezone picker's search text |
| `current_week_start` | schedule | mount | the Monday of the week on screen |
| `current_month` | schedule | mount | the month on screen (month calendar) |
| `current_year` | schedule | mount | the year on screen (month calendar) |
| `calendar_today` | schedule | mount | today, in the booker's timezone |
| `calendar_landing` | schedule | mount | where the calendar opens (`CalendarHelpers.landing_week/1`) |
| `month_availability_map` | schedule | mount | which days of the month have a slot; `:loading` or `nil` until fetched |
| `availability_status` | schedule | mount | the month fetch's state (`:not_loaded`, `:loading`, `:error`, ...) |
| `booking_window_days` | schedule | mount | how many days ahead the organiser takes bookings |
| `selected_date` | schedule, booking, confirmation | mount | the day the booker chose |
| `selected_time` | schedule, booking, confirmation | mount | the time the booker chose |
| `available_slots` | schedule | mount | the chosen day's slots |
| `loading_slots` | schedule | mount | whether the day's slots are loading |
| `calendar_error` | schedule | mount | why the day's slots could not be fetched |
| `slot_interval_minutes` | schedule | mount | the interval of the slots on screen |
| `duration_minutes` | schedule | mount | the meeting length the slots are for |
| `expanded_hour` | schedule | mount | the hour group open in the slot list |
| `entered_via_overview` | schedule | mount | whether the booker came from the overview (shows Back) |
| `week_slots` | schedule | mount | the week of slots, `nil` until the step sends `load_week` (see [A week of slots](#a-week-of-slots)) |
| `week_slots_loading` | schedule | mount | whether the week is loading |
| `week_slots_error` | schedule | mount | why the week could not be fetched |
| `engine` | questions | mount | the custom-questions engine; `CustomQuestions.Events.assign_render_state/1` derives the question on screen from it |
| `form` | booking | mount | the booking form |
| `validation_errors` | booking | mount | the booking form's visible errors |
| `submitting` | booking | mount | whether the booking is being submitted |
| `is_rescheduling` | booking, confirmation | mount | whether this booking replaces an earlier one |
| `guest_emails` | booking, confirmation | mount | the guests added |
| `guests_open` | booking | mount | whether the guest field is open |
| `guest_input` | booking | mount | the guest address being typed |
| `guest_error` | booking | mount | why a guest address was refused |
| `max_guests` | booking | mount | how many guests the meeting type allows |
| `location_options` | booking | mount | the meeting type's locations |
| `location_video_choices` | booking | mount | the video providers per location |
| `selected_location_id` | booking | mount | the chosen location |
| `selected_video_id` | booking | mount | the chosen video provider |
| `location_phone` | booking | mount | the phone number typed for a phone location |
| `location_error` | booking | mount | why the location answer was refused |
| `name` | confirmation | mount | the booker's name (from the confirmation route) |
| `email` | confirmation | mount | the address the confirmation went to |
| `meeting_uid` | confirmation | mount | the booked meeting's id (for the calendar file link) |
| `owner_preview` | confirmation | mount | whether the organiser is previewing their own page |
| `custom_fields_snapshot` | confirmation | mount | the custom questions as they were when booked |
| `custom_field_answers` | confirmation | mount | the booker's answers |
| `meeting_status` | confirmation | optional | the booked meeting's status, set once a booking is submitted |
<!-- step-assigns:end -->

The wrapper's assigns are listed under [Theme Template Rendering](#theme-template-rendering).

#### 5. **Shared Modules**

Leverage the shared modules rather than duplicating them: the table under [Shared Modules You'll Use](#shared-modules-youll-use) lists each, and [Shared Components](#shared-components) the components a step renders.

#### 6. **Event Communication Pattern**

Templates send one of the canonical events (listed in `Shared.StepEvents`'s moduledoc) with `phx-target={@myself}`; the component delegates `handle_event/3` to `Shared.StepEvents`, which relays `{:step_event, step, event, data}` to the LiveView, where `SchedulingFlow.handle_step_event/4` handles it. A theme never writes its own relay. For an event of its own, a template sends `phx-click="theme:<name>"` (with `phx-target={@myself}`); the relay forwards it untouched and the macro calls your `handle_theme_event(name, params, socket)` with the prefix stripped, from whichever step sent it (`socket.assigns.current_state` says which). The prefix cannot take over a canonical event: `theme:next_step` reaches your hook as `"next_step"` and moves nothing. An unprefixed step event the flow does not handle is dropped with a warning (theme id, step, event; once per name and page view), on every step. Any visitor can send `theme:<anything>`, so an override of the hook replaces its default wholesale and must end with a catch-all clause, or an unknown name raises. Make it `defp handle_theme_event(event, params, socket), do: super(event, params, socket)`: the default logs the name with the same warning and returns `{:noreply, socket}` (the fixture theme's `live.ex` shows the pattern).

### Theme Template Rendering

You do not write `render/1`: `use SchedulingLive, wrapper:, steps:` generates it
through `Shared.SchedulingPage`. Your wrapper receives `theme_tokens`,
`locale`, `language_dropdown_open`, `current_state`,
`organizer_user_id`, `owner_preview`, `should_show_branding` (which may be absent),
`demo_mode` when the LiveView assigned one, and an inner block;
`steps:` must name a LiveComponent for each of `:overview`, `:schedule`, `:questions`,
`:booking` and `:confirmation`, and no other key, which compilation checks.

### Markup the shared tests rely on

The shared test suites, their helpers, the end-to-end suites and the visual harness find elements on a booking page by markup, not by what a theme calls things. A theme that does not render a hook below fails them, usually with "element not found". A theme that builds its steps from the shared components (`SlotList`, `WeekGrid`, `TimezonePicker`, `BookingForm`, `GuestField`, `LocationField`, `ApprovalNotice`, `CustomAnswers`, `ThemeShell`, and `MeetingPageBodies` through `Shared.DefaultPages`) gets most of these for free; the tables mark each hook "shared" (the component renders it, you keep it) or "theme" (you render it).

The readers are: the flow helpers (`test/support/theme_booking_flow_helpers.ex`, `booking_test_helpers.ex`, `week_view_test_helpers.ex`), the suites that loop over `ThemeTestMatrix.all/0` (`theme_booking_flow_test.exs`, `theme_booking_step_parity_test.exs`, `theme_approval_disclosure_test.exs`, `booking_accessibility_test.exs`, `guest_booking_flow_test.exs`, `custom_fields_booking_flow_test.exs`, `reschedule_entry_test.exs`, `linked_date_test.exs`, `visitor_today_test.exs`, `timezone_change_selection_test.exs`, `booker_hook_classes_test.exs`, `ignored_step_event_test.exs`, the meeting and readiness suites), the e2e suite `embed_sizes_matrix_test.exs`, and the visual harness (`SEL` and `MASKS` in `capture.mjs`). Quote a hook exactly: the tests use `data-testid` for what is stable and a class or event name only where it is listed here. A theme also has an entry in `ThemeTestMatrix` (`wrapper_class`, `schedule_view`, `selected_duration_selector`, `video_background`, `pins_schedule_actions`), and the suites read those fields instead of a hard-coded name.

#### Whole page

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| The `wrapper_class` of the `ThemeTestMatrix` entry (for example `quill-theme-wrapper`) | the outermost element of every page the theme draws: the booking page, the readiness notice, the cancel and reschedule pages | theme (`class` on `ThemeShell`) | dispatcher, readiness, ignored-event and meeting-management suites |
| `.booker-page` | the theme grid | shared (`ThemeShell` adds it) | `booker_hook_classes_test.exs`, `shared/embed.css` |
| `.booker-card` | every card on a step and on the meeting, poll and payment pages | theme | `booker_hook_classes_test.exs` (on the overview), `shared/embed.css` |
| `[data-phx-component]` | the root of each step: a step is a LiveComponent, and its events are sent to it (`with_target`) | theme (a `steps:` component) | `ignored_step_event_test.exs` (`[data-phx-component]:has([data-testid='duration-option'])`), `week_view_test_helpers.ex` |
| `[data-testid="readiness-notice"]` | the notice shown instead of the flow when the organiser has no calendar | shared (`SchedulingPage`, `ErrorComponent`) | `no_calendar_readiness_test.exs`, `poll_voting_mount_test.exs` |
| `[data-testid="preview-notice"]` | the owner-preview banner | shared (`ThemeShell`) | `owner_preview_booking_test.exs` |
| `.lang-switcher button[phx-click="toggle_language_dropdown"]` and `button[phx-click="change_locale"][phx-value-locale]` | the language switcher | shared (`ThemeShell`) | `embed_primary_colour_test.exs` |
| The configured theme extensions (an element with the id the extension chooses, `data-theme-id` set from `theme_id`) | the grid's footer row | shared (`ThemeShell`) | `layout_extension_test.exs`, the e2e branding-footer check |
| `[data-phx-main].phx-connected` | the LiveView root, once connected | Phoenix | e2e suites, visual harness |
| `#background-motion-toggle` (`phx-hook="BackgroundMotionToggle"`, `aria-label`, `data-label-pause`, `data-label-play`) next to a `<video>` | the page, only when the theme's `video_background` is true | shared (`<.background_motion_toggle />`); you render the `<video>` | `booking_accessibility_test.exs`, the `BackgroundMotionToggle` hook |
| `[data-visual-mask]`, `.timezone-time-display`, `.timezone-offset-badge` | text that changes between runs (the visitor's local clock, today's UTC offset) | theme (optional) | visual harness `MASKS`; a theme can add its own in its harness module's `masks` |

#### Overview step

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| `[data-testid="duration-option"]` | a `<button>` per meeting type, with `phx-click="select_duration"`, `phx-value-duration` and `data-duration` both the meeting type's slug (`MeetingTypes.effective_slug/1`) and `phx-target={@myself}`; choosing the chosen one again keeps it chosen | theme | flow helpers, `BookingTestHelpers`, parity, reschedule and approval suites, e2e, visual harness (`[data-duration="<slug>"]`) |
| The `selected_duration_selector` of the `ThemeTestMatrix` entry | matches the card only while it is selected (Quill marks the button with `.duration-card--selected`, Rhythm its wrapper with `.selected`) | theme (you choose the marker and register the selector) | `reschedule_entry_test.exs` |
| `[data-testid="next-step"]` | a `<button>` with `phx-click="next_step"` and `phx-target={@myself}`, `disabled` until a duration is chosen | theme | flow helpers, parity and reschedule suites, e2e, visual harness |
| `[data-testid="approval-pill"]` | inside the duration card of a meeting type that needs approval (`Approval.required?/1`) | shared (`ApprovalNotice.pill/1`), placed by the theme | `theme_approval_disclosure_test.exs` |

#### Schedule step: calendar view

A theme whose `schedule_view` is `:calendar` (days, then the chosen day's times).

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| `[data-testid="calendar-day"]` | a `<button>` per day with `data-date` (ISO date), `phx-click="select_date"`, `phx-value-date`, `phx-target`; `disabled` while the day has no times, is outside the month on show, or availability is loading; `aria-current="date"` on today in the visitor's timezone; the chosen day carries the class `selected` or `calendar-day--selected` | theme | flow helpers (`:not([disabled])` and `phx-value-date`), `BookingTestHelpers`, `visitor_today_test.exs`, `linked_date_test.exs`, `timezone_change_selection_test.exs`, e2e, visual harness, and `AutoScrollToSlots` (moves focus on from a button matching `[data-testid="calendar-day"]` or `.week-day-cell`) |
| `.calendar-day--loading` (or `.loading` on a `.week-day-cell`) | a day button while its availability is loading | theme | visual harness waits for it to clear |
| `.calendar-day--other-month` | a padded day of the neighbouring month, if the grid pads | theme (optional) | visual harness (`SEL.day` ignores it) |
| `button.calendar-nav-button` | each calendar navigation button, with `phx-click` `prev_month`, `next_month`, `prev_week` or `next_week`, `disabled` at the edge of the booking window | theme | `BookingTestHelpers` (`button[phx-click="next_month"]`, `prev_month`, `next_week`), visual harness (`[phx-click^="next"]`) |
| `.calendar-month-label` | on a month-paged calendar (one with a `next_month` button): the month and year, as `LocalizationHelpers.get_month_year_display/2` writes them | theme | `BookingTestHelpers.showing_month?/2` and `show_month/3` |
| `[data-testid="schedule-actions"]` | the row that holds Back and Next | theme | `embed_sizes_matrix_test.exs` (overlap, reachability and pinning checks) |
| `[data-testid="next-step"]` | a `<button>` with `phx-click="next_step"`, `disabled` until a date and a time are chosen | theme | flow helpers, e2e, visual harness |
| `[data-testid="back-step"]` | a `<button>` with `phx-click="back_step"`, only when `@entered_via_overview` | theme | e2e, `custom_fields_booking_flow_test.exs`, visual harness |
| `#slots-container.slot-list` (`phx-hook="AutoScrollToSlots"`), `.slot-list__heading` (`tabindex="-1"`), `[data-slots-loaded]` (the chosen date) | the time list; the hook scrolls to it and focuses the heading once times load | shared (`SlotList`) | `AutoScrollToSlots`, `slot_list_test.exs` |
| `[data-testid="time-slot"]` | a `<button>` per time with `data-time`, `phx-value-time`, `phx-click="select_time"` | shared (`SlotList`) | flow helpers, `BookingTestHelpers`, timezone, reschedule and e2e suites, visual harness |
| `[data-testid="slot-hour"]` | the hour button of a by-hour list (`phx-value-hour`, `aria-expanded`) | shared (`SlotList`) | `SlotPickerTestHelpers.rendered_hours/1`, visual harness |
| `button.tz-picker__trigger`, `.tz-picker__search` | the timezone trigger (accessible name contains its visible text, announces its dialog) and the search box | shared (`TimezonePicker`) | `booking_accessibility_test.exs` |

#### Schedule step: week-grid view

A theme whose `schedule_view` is `:week_grid` renders the shared `WeekGrid` instead of the calendar and the time list, so it has no `calendar-day` or `time-slot` buttons.

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| `[data-testid="week-grid"]` | the grid, inside the schedule step's LiveComponent (`target={@myself}`), so `load_week` reaches it | shared (`WeekGrid`) | `WeekViewTestHelpers.week_view?/1` and `load_week/1`, which choose the picker |
| `[data-testid="week-slot"]` | a `<button>` per free time with `data-date`, `data-time`, `phx-click="select_slot"`, `disabled` while the week loads | shared (`WeekGrid`) | `WeekViewTestHelpers`, flow helpers, `custom_fields_booking_flow_test.exs` |
| `[data-testid="week-grid-prev"]`, `[data-testid="week-grid-next"]` | the week buttons (`prev_week`, `next_week`) | shared (`WeekGrid`) | `WeekViewTestHelpers` |
| `.week-grid__nav` | the navigation row | shared (`WeekGrid`) | `embed_sizes_matrix_test.exs` (overlap check) |
| `[data-testid="schedule-actions"]`, `[data-testid="next-step"]`, `[data-testid="back-step"]` | as in the calendar view | theme | flow helpers, e2e |
| `button.tz-picker__trigger`, `.tz-picker__search` | as in the calendar view | shared (`TimezonePicker`) | `booking_accessibility_test.exs` |

The visual harness has no selector for the grid: a theme that uses it supplies `openSchedule` and `pickSlot` in its harness module.

#### Questions step

The step appears only when the meeting type has custom questions. The engine renders the inputs; the theme renders the navigation.

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| `button[phx-click="next_step"][phx-target]` and `button[phx-click="back_step"][phx-target]` | one of each on screen, so a test's selector is unambiguous | theme | `custom_fields_booking_flow_test.exs`, `long_single_select_flow_test.exs`, visual harness (`next` or `next_step`) |
| `form[id^="cq-form-"]` (`phx-submit="next_step"`), `input[name="value"]`, `select[name="value"]` | a text-like question and a long single select | shared (custom-questions inputs) | `long_single_select_flow_test.exs`, `custom_fields_booking_flow_test.exs`, visual harness |
| `label.custom-question-option-card`, `label.custom-question-yes-no-tile` (`.is-yes`, `.is-no`, inside `.custom-question-yes-no`), `input[type="checkbox"][phx-value-value]` | the option, yes/no and acknowledgement inputs | shared (custom-questions inputs) | `custom_fields_booking_flow_test.exs`, `embed_sizes_matrix_test.exs`, visual harness |

#### Booking step

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| `form[data-testid="booking-form"]` (`id="booking-form"`, `novalidate`, `phx-submit="submit"`) | the booking form | shared (`BookingForm`) | flow helpers, e2e, visual harness, parity and custom-field suites |
| `[name="booking[name]"]`, `[name="booking[email]"]`, `[name="booking[message]"]` (`input#booking-form_name` and `input#booking-form_email` `required`; a `<span class="text-red-500">` in `label[for="booking-form_name"]` and `label[for="booking-form_email"]`; `.input-error` on an invalid field) | the form's fields | shared (`BookingForm`, the core `input`) | flow helpers, parity suite, visual harness, e2e |
| `booking[website]` (honeypot), `booking[g-recaptcha-response]`, `.recaptcha-notice`, `phx-hook="RecaptchaV3"` on the form when reCAPTCHA is on | the anti-spam fields | shared (`BookingForm`) | `theme_booking_step_parity_test.exs` |
| `[data-testid="submit-booking"]` | a `<button type="submit" form="booking-form">`, `disabled` until the form is valid and while submitting; its label comes from `BookingLabels.submit_label/3` (it must read "Request meeting", not "Book Meeting", when approval is required) | theme | flow helpers, approval suite, visual harness |
| `[data-testid="back-step"]` | a `<button>` with `phx-click="back_step"` | theme | `custom_fields_booking_flow_test.exs`, e2e, visual harness |
| `[data-testid="guest-toggle"]`, `guest-input`, `guest-add`, `guest-chip`, `guest-close` (and `form.guest-add` with `novalidate`) | the guest field, inside the form's block | shared (`GuestField`) | `guest_booking_flow_test.exs`, visual harness |
| `[data-testid="location-field"]`, `location-option`, `location-error`, `video-provider-field`, `video-provider-option` (`data-video-integration-id`) | the location choice, when the meeting type offers one | shared (`LocationField`) | `location_choice_flow_test.exs`, visual harness |
| `[data-testid="approval-notice"]` | a block above the submit button, when the meeting type needs approval | shared (`ApprovalNotice.block/1`), placed by the theme | `theme_approval_disclosure_test.exs` |

#### Confirmation step

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| `[data-testid="confirmation-heading"]` | the heading shown once the booking is made (and not shown while a preview or a failed booking blocks it) | theme | flow helpers, booking flow and guest suites, visual harness |
| `[data-testid="add-to-calendar"]` | an `<a>` to `PathHandlers.calendar_ics_path/1`, rendered only when a `meeting_uid` is known | theme | `custom_fields_booking_flow_test.exs`, visual harness (`confirmationCta`) |
| `[data-testid="schedule-another"]` | a `<button>` with `phx-click="schedule_another"` | theme | `reschedule_completion_test.exs`, visual harness (`confirmationCta`) |
| `.custom-answers`, `.custom-answers__value` | the booker's answers | shared (`CustomAnswers`) | `long_single_select_flow_test.exs` |
| `[data-testid="approval-notice"]` | when the booking awaits approval (`ApprovalDisplay.awaiting_approval?/1`) | shared (`ApprovalNotice.block/1`), placed by the theme | `theme_approval_disclosure_test.exs` |
| `[data-testid="awaiting-payment"]` (`#awaiting-payment`, `phx-hook="PaymentRedirectOpenTab"`) | the placeholder for a paid embedded booking | shared (`SchedulingPage`, `AwaitingPayment`) | visual harness |

#### Meeting, poll and payment pages

A theme with a `page_shell:` gets all of these from the shared bodies. A theme with its own pages renders them itself.

| Hook | Must be on | Provided by | Read by |
|---|---|---|---|
| `[data-testid="cancel-meeting"]` and `[data-testid="keep-meeting"]` | `<button>`s on the cancel page with `phx-click="cancel_meeting"` and `phx-click="keep_meeting"`, `disabled` while the request runs | shared (`MeetingPageBodies.cancel/1`); Quill and Rhythm render them in their own markup | `theme_booking_flow_test.exs`, `dispatcher_cancel_composition_test.exs`, visual harness (`cancel-meeting`) |
| A `<button>` reading "Choose New Time" (`[data-testid="reschedule-choose-time"]` in the shared body) | the reschedule page, navigating to the organiser's booking page with `reschedule_meeting_uid` | shared (`MeetingPageBodies.reschedule/1`); Quill and Rhythm render their own button | `theme_meeting_test_cases.ex` (found by its text), `default_pages_journey_test.exs` |
| A `<button>` reading "Schedule a New Meeting" | the cancel-confirmed page, navigating to `/` | shared (`MeetingPageBodies.cancel_confirmed/1`); Quill and Rhythm render their own button | `theme_meeting_test_cases.ex` (found by its text) |
| `[data-testid="<theme key>-payment-processing"]` and `[data-testid="<theme key>-payment-cancelled"]` | the payment return pages, which also load the theme's stylesheet | shared (`DefaultPages`) or theme | `payment_return_live/theme_shell_test.exs` |
| `[data-testid="poll-register-form"]`, `poll-name`, `poll-email`, `poll-register-submit`, `poll-vote-form`, `poll-save-votes`, `poll-participant-name` | the poll voting page | shared (`PollVotingComponents`) | `poll_voting_mount_test.exs`, visual harness |

A theme's own `scheduling-theme-<slug>.css` and the `<slug>-theme` class on the page are covered under [CSS Architecture](#css-architecture); the suites read them too (`theme_integration_test.exs`, `meeting_management_theme_test.exs`).

## Theme Customization System

### Background Options

Themes can offer users four types of backgrounds:

1. **Gradients** - CSS gradients defined in `Tymeslot.ThemeCustomizations.Presets.get_gradient_presets/0`
2. **Solid Colors** - User-selected hex colors
3. **Preset Images/Videos** - Pre-defined options stored in `/priv/static/`
4. **Custom Uploads**: user-uploaded images or videos, for the fields the spec's option groups declare (`asset_fields/1`). `ThemeCustomizations.attach_asset/4` stores the file under a name of its own, saves the owning group's `upload_changes/3` and, for a video, queues transcoding; the dashboard declares upload inputs only for declared fields.

### Preset Assets Structure

Preset assets are organized in the static directory:

```
priv/static/
├── images/themes/backgrounds/   # Preset background images (and their -thumbnail files)
│   ├── artistic-studio.webp
│   ├── ocean-sunset.webp
│   └── ...
├── videos/backgrounds/          # Preset background videos
│   ├── blue-wave-desktop.webm   # Desktop WebM
│   ├── blue-wave-desktop.mp4    # Desktop MP4
│   ├── blue-wave-mobile.mp4     # Mobile optimized
│   ├── blue-wave-low.mp4        # Low bandwidth
│   └── ...
└── images/ui/posters/           # Video posters (thumbnails)
    ├── blue-wave-thumbnail.jpg
    └── rhythm-background-poster.jpg
```

Booking pages and the dashboard picker both read preset images from `/images/themes/backgrounds/`; `Options.Background.preset_image_url/1` owns the path, and `descriptor/1` resolves a preset through it.

### Defining Presets

Presets are defined under `lib/tymeslot/theme_customizations/presets/`, one module per kind (`ColourSchemes`, `Gradients`, `Images`, `Videos`, `Covers`, `Accents`, `Fonts`), each holding its data and exporting `all/0`. Everything outside the catalogue reads them through the `Tymeslot.ThemeCustomizations.Presets` facade: `find_preset_by_id/2` and `take/2` for any kind, and the per-kind getters. A new kind of preset is a module there and one entry in the facade's private `kinds/0` map. A theme offers a preset only when its spec's group lists the id.

**Available Video Presets**:
- `"preset:rhythm-default"`
- `"preset:blue-wave"`
- `"preset:dancing-girl"`
- `"preset:leaves"`
- `"preset:light-green"`
- `"preset:space"`

**Available Image Presets**:
- `"preset:artistic-studio"`
- `"preset:rustic-farmhouse"`
- `"preset:space-satellite"`
- `"preset:elegant-still-life"`
- `"preset:ocean-sunset"`

**Available Cover Presets** (`Presets.Covers`, for an `Options.Cover` group's `presets:`; the last three are covers of their own under `/images/themes/covers/`, each entry recording its Pixabay `source`):
- `"elegant-still-life"`
- `"artistic-studio"`
- `"ocean-sunset"`
- `"rustic-farmhouse"`
- `"botanical"`
- `"studio-light"`
- `"paper-texture"`

## Advanced Video Features

### Video Container Rendering

For themes with video backgrounds, use the `VideoSources` shared component to render `<source>` elements inside your video container. Import it in your wrapper:

```elixir
import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]
```

Then use it in your wrapper template:

```heex
<div class="your-video-container">
  <video autoplay muted loop playsinline poster={@background.poster}>
    <.video_sources sources={@background.sources} />
  </video>
</div>
```

The source list comes from `Options.Background.descriptor/1`: an uploaded video's transcoded variants followed by the original, or a preset's five sizes. `@background.poster` is the preset's poster (nil for uploads).

### Multi-Quality Video System

The video system automatically selects the best quality based on the filename suffix:
- `-desktop.webm`: Best quality for modern browsers
- `-desktop.mp4`: Standard desktop quality
- `-mobile.mp4`: Optimized for tablets and phones
- `-low.mp4`: Low bandwidth fallback

## Multi-Lingual Support

### Overview

Tymeslot booking pages support internationalization (i18n) with automatic browser language detection.

**Supported Languages:**
- 🇬🇧 English (`en`)
- 🇩🇪 German (`de`)
- 🇺🇦 Ukrainian (`uk`)
- 🇫🇷 French (`fr`)
- 🇮🇹 Italian (`it`)
- 🇨🇿 Czech (`cs`)
- 🇵🇱 Polish (`pl`)

### Language Switcher Integration

`ThemeShell` renders the language switcher for every theme's wrapper, inside a container carrying the wrapper's `language_class`, and only when the page passes both `locale` and `language_dropdown_open`. `show_language_switcher` (derived by `prepare_wrapper_assigns/1`) adds `visible` or `hidden` to that container.

### Path Generation & Localization

Always use `PathHandlers` for internal links to preserve the user's locale:

```elixir
# Path with current locale and theme preserved
path = PathHandlers.build_path_with_locale(socket, @locale)
```

Use `LocalizationHelpers` for all date and time formatting:

```elixir
# Localized: "Wednesday, 15 March 2024"
LocalizationHelpers.format_date(@selected_date)
```


## Development Workflow

### Step-by-Step Implementation

Copy an existing theme (Quill or Rhythm), rename its files and modules to your theme's name, then work through the [Summary Checklist](#summary-checklist) in order: it lists every file and line a new theme touches.

### What to Copy vs. What to Customize

**Don't copy at all** — the shared macro provides this automatically:
- `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: …, steps: …` replaces all LiveView event handlers, state init, `render/1`, and shared module wiring
- No per-theme `state_machine.ex` — `StateMachineHelpers` is shared

**Customize** (theme-specific):
- `wrapper:` and `steps:` passed to `use SchedulingLive`
- `handle_theme_event/3` override: for events of your own (`theme:<name>` from a step template, on any step), ending with a catch-all clause that calls `super/3`; step navigation (`navigate_to_step`) and every canonical step event the flow handles are handled before it and cannot be overridden
- Wrapper component layout and design
- Step component templates and styles
- CSS modules and variables
- Meeting action component designs (use `<.meeting_detail_rows .../>` for the rows)

**Do not re-derive in your wrapper or step components** (already in socket assigns):
- `organizer_user_id`: set during mount by `OrganizerHelpers.handle_username_resolution/2` (`TymeslotWeb.Live.Scheduling.OrganizerHelpers`), with the rest of the organiser's context. Do not extract it from `organizer_profile` in the wrapper or a step component; read `@organizer_user_id` directly.

### Testing Your Theme

Run the production checklist to validate your theme:

```bash
# Test all registered themes
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs

# Or test a specific theme
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs --only theme:3
```

The checklist automatically verifies:
- Theme renders without crashing
- All meeting types display correctly
- Edge cases work (no meeting types, long names)
- Basic mobile readiness

The theme's `ThemeTestMatrix` entry adds it to `theme_contract_test.exs`, the shared booking-flow suites (which walk the step transitions) and the e2e `embed_sizes_matrix_test.exs` (embed widths and short heights, run with `mix test.e2e`).

### Debugging Tips

**Common Issues**:

1. **Component not found**: Check aliases in theme module match component names
2. **CSS not loading**: Verify `theme.css` imports all modules in correct order
3. **State transitions broken**: Check `StateMachineHelpers.validate_state_transition/3`
4. **`:questions` step skipped or stuck**: Confirm the meeting type actually has custom fields — `StateMachineHelpers.states_for/1` only inserts `:questions` when `custom_fields` is non-empty
5. **Availability not loading**: Ensure InfoHandlers are implemented
6. **Form submission fails**: Check BookingFlow integration

**Debug helpers**:

```elixir
# In LiveView mount, render, or handle_info
require Logger
Logger.debug("Socket assigns: #{inspect(socket.assigns)}")
```

## Best Practices

### Do's

✅ **Use the `SchedulingLive` macro** - It provides all common LiveView callbacks
✅ **Use shared modules** - StateMachineHelpers, EventHandlers, InfoHandlers, BookingFlow
✅ **Implement all required callbacks** - the compiler checks the behaviour; `theme_contract_test.exs` checks what each callback renders
✅ **Keep LiveView thin** - `live.ex` holds the `use SchedulingLive` line and, at most, your own event hooks; the page lives in the wrapper and step components
✅ **Use LocalizationHelpers** - For all date/time formatting
✅ **Test with production checklist** - Automated validation catches issues early
✅ **Copy existing themes** - Rhythm and Quill are proven implementations

### Don'ts

❌ **Don't hardcode dates/times** - Always use LocalizationHelpers
❌ **Don't create a per-theme StateMachine** - `StateMachineHelpers` owns transitions; change `StateMachineHelpers`, which every theme shares, for custom logic
❌ **Don't duplicate shared logic** - Use the Shared.* modules
❌ **Don't mix theme and app styles** - Keep theme CSS isolated
❌ **Don't forget meeting actions** - Reschedule, cancel, cancel_confirmed required (or a `page_shell:`, which takes them from `Shared.DefaultPages`)
❌ **Don't over-engineer** - Start simple, add complexity only when needed

## Summary Checklist

Every place a new theme touches, in the order to add them (`aurora`, id `"3"`, as the example):

- [ ] **Catalog facts** in `lib/tymeslot/themes/catalog.ex`: `id`, `key`, `name`, `heading_style`, `status` (start at `:beta`) and `customization_spec:`
- [ ] **Registry binding** in `lib/tymeslot_web/themes/core/registry.ex`: one `"3" => TymeslotWeb.Themes.Aurora.Theme` line in `@bindings` (the build fails, naming the id, until both halves exist)
- [ ] **`theme.ex`**: one `use TymeslotWeb.Themes.Core.Theme, live_view:, preview_image:, description:` (the description a `dgettext_noop/2` call)
- [ ] **Translations**: `mix gettext.extract --merge` adds the description's msgid to every locale's `dashboard_appearance.po`; translate it there, or CI's `gettext.extract --check-up-to-date` fails
- [ ] **`scheduling/live.ex`**: one `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper:, steps:`, with the aliases above it, naming your `scheduling/wrapper.ex` and all five steps
- [ ] **Step components** under `scheduling/components/`: render-only LiveComponents that delegate `update/2` and `handle_event/3` to `Shared.StepEvents` (the questions step delegates `handle_event/3` to `Shared.CustomQuestions.Events` instead) and use the canonical event names, plus `theme:<name>` for an event of the theme's own, handled in `live.ex`'s `handle_theme_event/3`; the schedule step wires its navigation buttons to the `CalendarNavigation` boundary checks
- [ ] **Page templates**: either a `page_shell:` (recommended: one function component, the six pages from `Shared.DefaultPages`, with `shared/components/manage-pages.css` imported) or the six conventional modules, `meeting/` (`Reschedule`, `Cancel`, `CancelConfirmed`), `poll/voting.ex` and `payment/` (`Processing`, `Cancelled`), each with a `render/1`, or overrides of the generated render callbacks
- [ ] **Customisation spec**: a module that `use`s `Tymeslot.ThemeCustomizations.Spec` (see `QuillSpec`), the one `customization_spec:` names; options of the theme's own need a group module, a descriptor, their part of `tokens/2` and a panel (see [A theme with options of its own](#a-theme-with-options-of-its-own))
- [ ] **CSS tree** under `assets/css/scheduling/themes/aurora/`: `theme.css` importing `../../shared/entry.css` first, then `./modules/variables.css`, `../../shared/tokens.css`, `./modules/base.css`, `../../shared/embed.css` (the shared embed rules, which `entry.css` does not import), the theme's modules and the `shared/components/*.css` files it uses (every file in `REQUIRED_SHARED_IMPORTS` among them, or `mix css.check_tokens` fails naming it); `modules/variables.css` defining every token `mix css.check_tokens` requires (the scale tokens listed under [Token contract](#token-contract) included) and every colour; `modules/iframe.css` for the theme-specific embed rules; the `booker-card` hook class on each card (`ThemeShell` adds `booker-page` to the page grid and the shared `SlotList` adds `booker-scroll`; a page that bypasses `ThemeShell`, as Quill's payment pages do, adds `booker-page` itself)
- [ ] **Build config**: nothing to add. `assets/css/scheduling/themes/aurora/theme.css` gives the theme its Tailwind profile (writing `scheduling-theme-aurora.css`), its `tailwind_aurora` dev watcher and its `assets.build`/`assets.minify` entries, all derived by `config/theme_stylesheets.exs`; restart the dev server to pick up a new directory
- [ ] **Preview image** at `priv/static/images/ui/theme-previews/aurora-theme-preview.webp`, the path `preview_image:` names
- [ ] **`ThemeTestMatrix` entry** in `test/support/theme_test_matrix.ex`, with `fixture: false` and `schedule_view: :calendar` (a calendar of days, then the chosen day's times) or `:week_grid` (the shared `WeekGrid`, which the shared flow helpers then drive through `Tymeslot.WeekViewTestHelpers`) (`fixture: true` marks a test-only theme registered through `config :tymeslot, :extra_themes` in `config/test.exs`, which the flow suites and the e2e embed matrix skip)
- [ ] Optional: **`onboarding_preview/1`** (see Quill's `onboarding_preview.ex`), so the onboarding wizard shows the theme's shape instead of the generic mock
- [ ] Optional, with option groups of its own: a panel module for each (one that `use`s `ThemeCustomization.Panel`), named in `option_panels:` on `use TymeslotWeb.Themes.Core.Theme`
- [ ] Optional, with a video background: a `phx-hook` on the video container, either an existing hook (`QuillVideo` for one looping video) or your own in `assets/js/video_hooks.js`, registered in `assets/js/bundles/public.js`

Then verify:

- [ ] `mix test` passes, including `theme_contract_test.exs` and the production checklist, and `mix css.check_tokens` is green
- [ ] Standalone (`/{username}?theme=3`) and embedded pages render at every size: no viewport breakpoints inside the card, and the iframe grows and shrinks with content, with no internal scrollbar in unconstrained inline embeds
- [ ] Set the Catalog `status` to `:active`, which puts the theme in the dashboard and onboarding pickers
- [ ] Localisation works for all supported languages
- [ ] Every background kind the spec offers renders, and the customisation panel saves each option
