# Theme Development Guide

This guide explains how to create new themes for Tymeslot.

## Architecture Overview

The theme system uses a centralized registry pattern that eliminates magic strings and provides type-safe theme access.

### Key Components

1. **Theme Catalog** (`Tymeslot.Themes.Catalog`) - Domain source of truth for theme *facts* (id, key, name, features, status)
2. **Theme Registry** (`TymeslotWeb.Themes.Core.Registry`) - Web layer; merges catalog facts with presentation bindings (module, CSS file, preview image)
3. **Theme Behaviour** (`TymeslotWeb.Themes.Core.Behaviour`) - Interface that all themes must implement
4. **SchedulingLive Macro** (`TymeslotWeb.Themes.Shared.SchedulingLive`) - Injects all common LiveView callbacks; a theme's `live.ex` is built on it
5. **Shared State Machine** (`TymeslotWeb.Themes.Shared.StateMachineHelpers`) - Owns state transitions and routing for all themes (no per-theme state machine)
6. **Shared Context** (`TymeslotWeb.Themes.Shared.*`) - Shared helpers, handlers, and components
7. **Capability System** (`Tymeslot.ThemeCustomizations.Capability`) - Capability-based customization logic
8. **Dispatcher & Loader** (`TymeslotWeb.Themes.Core.Dispatcher`, `TymeslotWeb.Themes.Core.Loader`) - Systems for dynamically loading and dispatching theme actions
9. **Event Bus** (`TymeslotWeb.Themes.Core.EventBus`) - Centralized event handling system for theme components
10. **Wrapper Components** (per-theme) - Provides theme-specific layout, backgrounds, and UI chrome

## Quick Reference

### File Structure for a Theme

```
lib/tymeslot_web/themes/[theme_name]/
├── theme.ex                    # Theme behaviour implementation
├── scheduling/
│   ├── live.ex                 # Main LiveView (uses the SchedulingLive macro)
│   ├── wrapper.ex              # Theme layout wrapper
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
├── payment_processing/         # Optional: paid-booking return pages
│   └── live.ex
└── payment_cancelled/
    └── live.ex
```

> **No per-theme `state_machine.ex`.** State transitions live in the shared
> `TymeslotWeb.Themes.Shared.StateMachineHelpers`. Both Quill and Rhythm have
> deleted their local state machine. See [Common Patterns](#common-patterns).
>
> Themes may add their own internal structure beyond the above — Quill nests
> `scheduling/components/schedule/panels.ex`, and Rhythm keeps a theme-local
> `shared/` directory (`meeting_ticket.ex`, `organizer_header.ex`,
> `status_badge.ex`) for components reused only within that theme.

```
assets/css/scheduling/themes/[theme_name]/
├── theme.css                   # Main entry point (imports shared primitives + modules)
└── modules/
    ├── variables.css           # Design tokens (colors, spacing, typography)
    ├── base.css                # html, body, theme wrapper, root grid
    ├── iframe.css              # Iframe shell rules
    ├── typography.css          # Text styles with fluid clamp() sizes
    ├── video.css               # Video background (if supported)
    ├── overview.css            # Organizer profile + avatar
    ├── calendar.css            # Calendar grid + container queries
    ├── time-slots.css          # Time slot grid + container queries
    ├── schedule-header.css     # Schedule header + timezone selector
    ├── booking-form.css        # Booking form + container queries
    ├── custom-questions.css    # Custom-questions step styling
    ├── confirmation.css        # Confirmation + container queries
    ├── payment-pages.css       # Paid-booking / awaiting-payment pages
    └── language-switcher.css   # Language switcher
```

> The module breakdown is **per-theme, not canonical** — themes are free to split
> further. Quill (glassmorphism) splits its UI into `glass-card.css`, `buttons.css`,
> `animations.css`, `spinner.css`, `steps.css`, `timezone.css`, `meeting-details.css`,
> and `text-utilities.css`; Rhythm keeps a single `components.css`. Only the broad
> concerns above are common to both. The booking-form file is `booking-form.css`
> (not `booking.css`).

### Required Behaviour Callbacks

```elixir
@callback states() :: map()
@callback css_file() :: String.t()
@callback components() :: map()
@callback live_view_module() :: module()
@callback theme_config() :: map()
@callback validate_theme() :: :ok | {:error, String.t()}
@callback initial_state_for_action(atom()) :: atom()
@callback supports_feature?(atom()) :: boolean()
@callback render_meeting_action(map(), atom()) :: Phoenix.LiveView.Rendered.t()
```

### Shared Modules You'll Use

| Module | Purpose |
|--------|---------|
| `LiveHelpers` | Mount and param handling |
| `EventHandlers` | Common UI events (locale, navigation) |
| `InfoHandlers` | Async tasks (availability fetching) |
| `SchedulingInit` | Socket state initialization — `assign_theme_state/2` for full scheduling state (prefer this), `assign_base_state/1` for core-only assigns |
| `BookingFlow` | Form validation and submission |
| `LocalizationHelpers` | Date/time/duration formatting: `format_date/1`, `format_duration/1`, `format_booking_datetime/3`, `format_time_by_locale/1` (respects locale 12h/24h setting — always use this for time slot display), `day_name_short/1` (localized weekday abbreviations), `get_week_display/1` (formatted week range string). Meeting types arrive pre-ordered by the user's configured `sort_order` — never re-sort them in theme components. |
| `Tymeslot.Timezones` | Human-readable timezone display: `Timezones.format/1` — use this in confirmation and booking components instead of string-splitting the IANA timezone identifier |
| `TymeslotWeb.Live.Scheduling.CalendarHelpers` | Calendar/week day generation (`get_week_days/4` — pass `@user_timezone`), week navigation (`handle_week_navigation/2`), availability fetching, slot parsing, `display_range/2` for visible date boundaries. **Note:** this lives under `live/scheduling/`, not `themes/shared/`. |
| `TymeslotWeb.Live.Scheduling.CalendarNavigation` | Navigation boundary checks: `prev_month_disabled?/3`, `next_month_disabled?/4` (pass `@organizer_profile.advance_booking_days`), `prev_week_disabled?/2`, `next_week_disabled?/3` (pass `advance_booking_days`) — wire these to nav button `disabled` attributes. Also under `live/scheduling/`. |
| `StateMachineHelpers` | Shared state model and transition logic — `default_states/0`, `states_for/1` (5-step flow when the meeting type has custom fields, 4-step otherwise), `determine_initial_state/1`, `can_navigate_to_step?/3`, `validate_state_transition/3`. Replaces the deleted per-theme state machines. |
| `PathHandlers` | Navigation with locale preservation; `organizer_scheduling_path/1` for back-to-calendar links in cancel/reschedule pages |
| `Customization.Helpers` | Wrapper background/customization helpers. Call `prepare_wrapper_assigns/1` once at the top of your wrapper (it derives `@has_video_background`, `@video_poster`, `@show_language_switcher`); use `get_background_style/1` for the inline gradient/colour/image style. There is no `generate_custom_css` — the `custom_css` string arrives as an assign already. |
| `Customization.Video` | Video background rendering — `render_video_container/2` (crossfade + loading fallbacks) |
| `LocaleHandler` | Locale metadata for the language switcher — `get_locales_with_metadata/0`, `supported_locales/0` |
| `SchedulingLive` | Shared LiveView macro — `use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "N"` injects all common callbacks; only `render/1` (and optional overrides) needed in your LiveView |
| `VideoSources` | Shared component rendering `<source>` elements for video backgrounds; import and use `<.video_sources theme_customization={@theme_customization} />` in your wrapper |
| `Shared.Components.MeetingDetails` | Shared `meeting_detail_rows/1` component for cancel/reschedule pages; renders date, time, timezone, and organizer rows with icons |
| `Shared.Components.AwaitingPayment` | Shared `awaiting_payment/1` component for the transitional `:awaiting_payment` state in paid embedded bookings — `<AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />` |
| `Shared.CustomQuestions.{Engine, Events, Inputs.Renderer}` | Shared engine, event delegation, and input renderers for the custom-questions step. Your theme's `CustomQuestionsComponent` provides the chrome and delegates `handle_event` to `Events`; `Inputs.Renderer` renders each field type. |

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
│   └── wrapper.ex
├── meeting/
│   ├── cancel.ex
│   ├── cancel_confirmed.ex
│   └── reschedule.ex
└── theme.ex

assets/css/scheduling/themes/aurora/
├── modules/
│   ├── variables.css           # Design tokens (colors, spacing, typography)
│   ├── base.css                # Root layout, theme wrapper
│   ├── iframe.css              # Iframe shell rules (required)
│   ├── typography.css          # Text styles with fluid clamp() sizes
│   ├── video.css               # Video background (if supported)
│   ├── overview.css            # Organizer profile (optional)
│   ├── calendar.css            # Calendar grid + container queries
│   ├── time-slots.css          # Time slot grid + container queries
│   ├── schedule-header.css     # Schedule header + timezone selector
│   ├── booking-form.css        # Booking form + container queries
│   ├── custom-questions.css    # Custom-questions step
│   ├── confirmation.css        # Confirmation step
│   ├── payment-pages.css       # Paid-booking pages (if payments supported)
│   ├── components.css          # Buttons, inputs, duration cards (or split further)
│   └── language-switcher.css   # Language dropdown
└── theme.css
```

**Tip**: Copy an existing theme (Quill or Rhythm) as a starting point and modify it.

### 2. Register Your Theme

Theme registration is split across **two** modules so the dependency only ever
flows web → domain:

**a. Theme facts** — add an entry to `@themes` in
`lib/tymeslot/themes/catalog.ex` (pure domain data: no module, CSS,
or image references):

```elixir
aurora: %{
  id: "3",
  key: :aurora,
  name: "Aurora",
  description: "Beautiful northern lights theme",
  features: %{
    supports_video_background: true,
    supports_image_background: true,
    supports_gradient_background: true,
    supports_custom_colors: true,
    flow_type: :multi_step,
    step_count: 4
  },
  status: :active
}
```

**b. Presentation bindings** — add an entry to `@bindings` (keyed by theme **id**)
in `lib/tymeslot_web/themes/core/registry.ex`:

```elixir
"3" => %{
  module: TymeslotWeb.Themes.Aurora.Theme,
  css_file: "/assets/scheduling-theme-aurora.css",
  preview_image: "/images/themes/aurora-preview.png"
}
```

`Registry` merges the two at compile time (`Catalog.all/0` ⨝ `@bindings`) into the
full `theme_definition` the web layer consumes. Domain code (profiles, theme
customizations) reads facts directly from `Catalog` and never reaches into the web
layer.

### 3. Implement Required Functions

Your theme module must implement the `TymeslotWeb.Themes.Core.Behaviour`:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Theme do
  @moduledoc """
  Aurora theme implementation with northern lights design and 4-step flow.
  """

  @behaviour TymeslotWeb.Themes.Core.Behaviour

  alias TymeslotWeb.Themes.Aurora.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Aurora.Meeting.{Cancel, CancelConfirmed, Reschedule}

  @impl TymeslotWeb.Themes.Core.Behaviour
  def states do
    %{
      overview: %{step: 1, next: :schedule, prev: nil},
      schedule: %{step: 2, next: :booking, prev: :overview},
      booking: %{step: 3, next: :confirmation, prev: :schedule},
      confirmation: %{step: 4, prev: :booking}
    }
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def css_file, do: "/assets/scheduling-theme-aurora.css"

  @impl TymeslotWeb.Themes.Core.Behaviour
  def components do
    %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def live_view_module do
    TymeslotWeb.Themes.Aurora.Scheduling.Live
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def theme_config do
    %{
      name: "Aurora",
      description: "Beautiful northern lights theme with smooth animations.",
      preview_image: "/images/ui/theme-previews/aurora-theme-preview.webp",
      flow_steps: 4,
      design_system: :northern_lights,
      supports_duration_selection: true,
      supports_inline_booking: false
    }
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def validate_theme do
    required_components = [:overview, :schedule, :booking, :confirmation]

    missing_components =
      Enum.filter(required_components, fn component ->
        not Code.ensure_loaded?(components()[component])
      end)

    if Enum.empty?(missing_components) do
      :ok
    else
      {:error, "Missing components: #{inspect(missing_components)}"}
    end
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def initial_state_for_action(live_action) do
    case live_action do
      :index -> :overview
      :overview -> :overview
      :schedule -> :schedule
      :booking -> :booking
      :confirmation -> :confirmation
      _other -> :overview
    end
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def supports_feature?(feature) do
    case feature do
      :duration_selection -> true
      :inline_booking -> false
      :step_navigation -> true
      :video_background -> true
      :aurora_effects -> true
      _other -> false
    end
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_meeting_action(assigns, action) do
    case action do
      :reschedule -> Reschedule.render(assigns)
      :cancel -> Cancel.render(assigns)
      :cancel_confirmed -> CancelConfirmed.render(assigns)
      _other -> raise "Unsupported meeting action: #{action}"
    end
  end
end
```

### 4. Test It Works

The production checklist automatically tests all registered themes:

```bash
# Run the production checklist
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs
```

This will verify:
- All meeting types are displayed
- Theme handles edge cases (no meetings, long names)
- Basic mobile responsiveness
- Acceptable load times

## CSS Architecture

### Modular Structure

Themes use a **modular CSS architecture** located in `assets/css/scheduling/themes/`:

```
assets/css/scheduling/themes/
├── shared/                        # Shared structural primitives only
│   ├── reset.css                 # CSS reset
│   ├── layout.css                # Border-radius scale, Tailwind import, display helpers
│   └── utilities.css             # Shared utility classes
├── quill/                         # Quill theme (glassmorphism) — fine-grained split
│   ├── modules/
│   │   ├── variables.css         # Design tokens
│   │   ├── base.css              # Root layout, theme wrapper
│   │   ├── iframe.css            # Iframe shell rules
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
│   │   ├── custom-questions.css  # Custom-questions step
│   │   ├── overview.css          # Organizer profile
│   │   ├── confirmation.css      # Confirmation step
│   │   ├── payment-pages.css     # Paid-booking pages
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
    │   ├── payment-pages.css
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

### Theme CSS Structure

Each theme's main CSS file (`theme.css`) imports shared primitives then theme modules:

```css
/* Import shared structural primitives */
@import "../../shared/reset.css";
@import "../../shared/layout.css";
@import "../../shared/utilities.css";

/* Foundation (variables MUST come first) */
@import "./modules/variables.css";
@import "./modules/base.css";
@import "./modules/iframe.css";
@import "./modules/video.css";
@import "./modules/typography.css";

/* Per-feature modules (order among these is not significant) */
@import "./modules/schedule-header.css";
@import "./modules/calendar.css";
@import "./modules/time-slots.css";
@import "./modules/booking-form.css";
@import "./modules/custom-questions.css";
@import "./modules/overview.css";
@import "./modules/confirmation.css";
@import "./modules/payment-pages.css";
@import "./modules/language-switcher.css";
```

**Note**: Variables must come first. Import order within component files doesn't matter since they're self-contained.

### Intrinsic Responsiveness

Themes use **CSS container queries** and **fluid sizing** instead of viewport breakpoints. Each component file is self-contained — it owns its base styles, container queries, and iframe overrides in one place.

**Container query context:** The primary content container (`.scheduling-box` for Rhythm, `.glass-morphism-card` for Quill) has `container-type: inline-size; container-name: scheduling;`. All child components can use `@container scheduling (...)` queries.

**Fluid sizing with `clamp()` and `cqi` units:**
```css
.slide { padding: clamp(0.75rem, 3cqi, 1.5rem); }
.calendar-day { padding: clamp(0.25rem, 1cqi, 0.75rem); }
```

The `cqi` unit resolves against the nearest ancestor with `container-type: inline-size`.

**Fluid grids with `auto-fit`:**
```css
.time-period-slots { grid-template-columns: repeat(auto-fit, minmax(5rem, 1fr)); }
```

**Container queries for discrete layout switches:**
```css
@container scheduling (min-width: 480px) {
  .calendar-monthly { display: grid; }
  .calendar-weekly { display: none; }
}
```

**What stays as `@media`:**
- Height-based switches (`@media (max-height: ...)`) — container height queries have limited support
- `prefers-reduced-motion`, `print`, `device-memory` — co-located in the component they affect
- Elements outside the container query context (e.g. language switcher, which sits outside the primary content container) — these must use viewport `@media` queries since `@container` only matches descendants of the container element

**Browser support:** Safari 16+, Chrome 105+, Firefox 110+.

### Template Guidelines

Templates define structure, CSS defines appearance:
- Use semantic CSS class names describing what the element IS (`.calendar-grid`, `.duration-card`)
- No visual classes in templates (no `rounded-xl`, `shadow-lg`)
- No layout classes in templates (no `flex-row`, `grid-cols-2`)
- No responsive classes in templates (no `sm:`, `md:`, `lg:`)
- Each theme owns its templates entirely — UI components are theme-specific, not shared

### Shared Components

The **step UI** is theme-owned. Duration cards, calendar day buttons, time-slot
buttons, and the booking form are rendered and styled by each theme — there is no
shared "duration card" component. Each theme renders its own markup and styles it
with its own CSS.

Shared across themes:

- **Data utilities** (`TymeslotWeb.Components.MeetingUtils`): `normalize_slot_list/1`
  and `normalize_slot_time/1` normalise time-slot data.
- **`Shared.Components.MeetingDetails`** (`meeting_detail_rows/1`) — the date/time/
  timezone/organizer row layout used by the cancel and reschedule pages.
- **`Shared.Components.AwaitingPayment`** (`awaiting_payment/1`) — the
  `:awaiting_payment` state placeholder for paid embedded bookings.
- **`Shared.VideoSources`** (`video_sources/1`) — `<source>` elements for video
  backgrounds, used inside each wrapper's `<video>` element.
- **`Shared.CustomQuestions.Inputs.Renderer`** plus the per-type input components —
  the custom-questions field renderers. The theme's `CustomQuestionsComponent`
  supplies the chrome (card, progress indicator) and delegates rendering and events
  to the shared engine.
- **`TymeslotWeb.Components.LanguageSwitcher`** (`language_switcher/1`) — the locale
  dropdown, rendered from each wrapper.

So the dividing line is: **per-step visual layout is theme-owned; cross-cutting
chrome and field rendering is shared.**

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

Each theme needs a small `iframe.css` (~30 lines) for iframe-specific shell rules:
- `height: max-content` on body for height reporting
- `position` fixes for elements that behave differently in iframes
- Hide footer/branding in embedded mode
- Reset the primary content container (`.scheduling-box`, `.glass-morphism-card`) to fill the iframe: `width: 100%; max-width: 100%; border-radius: 0; border: none;`

Size-driven compaction (compact calendar, smaller badges, form re-layout) is handled by container queries in each component file — the same queries that handle narrow viewports.

### Iframe Auto-Resize

When the scheduling page loads inside an iframe, `iframe_embed.js` continuously measures the page's content height and posts it to the parent on a 50ms loop. The parent iframe element grows AND shrinks to match — so themes should let the body flow to its natural content height in embedded mode (`height: max-content`, no `height: 100%` chains). See `themes/<theme>/modules/iframe.css` for the per-theme overrides.

The embedder can supply `data-initial-height` (px) on the container as a placeholder height shown before the first measurement lands; `data-min-height` is still accepted as a legacy alias. After the first message, the iframe always matches reported content height.

### Creating Theme CSS

1. **Create theme directory**: `assets/css/scheduling/themes/your-theme/`
2. **Create main theme.css** that imports shared primitives and your modules
3. **Create modular CSS files** in a `modules/` subdirectory — each component file is self-contained
4. **Set container query context** on the primary content container (`container-type: inline-size; container-name: scheduling;`)
5. **No external font imports** — use system font stacks or self-hosted fonts only

**Note**: Theme CSS is completely separate from global app styles.

## Theme Requirements

### Must Have
- Theme module implementing `TymeslotWeb.Themes.Core.Behaviour`
- LiveView module that renders without crashing (using the `SchedulingLive` macro)
- Wrapper component for theme layout
- CSS file in `assets/css/scheduling/themes/your-theme/theme.css`
- `modules/iframe.css` with `[data-embedded]`-scoped iframe shell rules
- Container query context (`container-type: inline-size`) on the primary content container
- The 4 core booking flow states: **overview**, **schedule**, **booking**, **confirmation**
- Handling for the conditional **`:questions`** state (custom-questions step, when the meeting type has custom fields) and the transitional **`:awaiting_payment`** state (paid embedded bookings)
- All 5 step components as LiveComponents (the 4 core steps + `custom_questions_component.ex`)
- Schedule component must include both the weekly strip (mobile) and monthly grid (desktop) with nav buttons wired to `CalendarNavigation` boundary checks
- Meeting action components (reschedule, cancel, cancel_confirmed)

> No per-theme StateMachine module — transitions are owned by the shared
> `StateMachineHelpers`.

### Nice to Have
- Smooth transitions
- Accessibility features

## Using Shared Logic and Helpers

The theme system provides centralized handlers and helpers in `TymeslotWeb.Themes.Shared.*` to ensure consistency and reduce duplication.

> **You normally do not write any of the code in this section by hand.** The
> `use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "N"` macro wires up
> `mount/3`, `handle_params/3`, every `handle_info/2`, and the language/booking/
> scheduling `handle_event/3` clauses for you (see [Common Patterns](#common-patterns)).
> The subsections below document the underlying helpers the macro calls — read them
> to understand what is happening, or when you need to override a specific extension
> point. The manual `mount/3`/`handle_params/3` example immediately below shows what
> the macro expands to; a real theme's `live.ex` only defines `render/1` plus optional
> `handle_theme_event/3` / `handle_theme_schedule_event/3` overrides.

### LiveHelpers

`TymeslotWeb.Themes.Shared.LiveHelpers` provides common mounting and parameter handling logic (invoked by the macro; shown here for reference):

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Live do
  use TymeslotWeb, :live_view
  require Logger

  alias TymeslotWeb.Themes.Shared.StateMachineHelpers, as: StateMachine
  alias TymeslotWeb.Themes.Shared.{
    EventHandlers,
    InfoHandlers,
    LiveHelpers,
    PathHandlers,
    SchedulingInit
  }

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    # Determine initial state from route
    initial_state = StateMachine.determine_initial_state(socket.assigns[:live_action])

    socket =
      LiveHelpers.mount_scheduling_view(
        socket,
        params,
        initial_state,
        &assign_initial_state/1,
        &setup_initial_state/3
      )

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    # Handle URL changes (back/forward navigation)
    new_state = StateMachine.determine_initial_state(socket.assigns[:live_action])

    LiveHelpers.handle_scheduling_params(
      socket,
      params,
      new_state,
      &handle_param_updates/2,
      &handle_state_entry/3
    )
  end

  # Private helpers required by LiveHelpers
  defp assign_initial_state(socket) do
    today = Date.utc_today()

    socket
    |> SchedulingInit.assign_base_state()
    |> assign(:theme_id, "3")
    |> assign(:duration, nil)
    |> assign(:meeting_type, nil)
    # ... additional initial state
  end

  defp handle_param_updates(socket, params) do
    LiveHelpers.handle_param_updates(socket, params)
  end

  defp setup_initial_state(socket, initial_state, params) do
    LiveHelpers.setup_initial_state(socket, initial_state, params, &handle_state_entry/3)
  end

  defp handle_state_entry(socket, :schedule, params) do
    LiveHelpers.handle_schedule_entry(socket, params)
  end

  defp handle_state_entry(socket, :booking, params) do
    LiveHelpers.handle_booking_entry(socket, params)
  end

  defp handle_state_entry(socket, _state, _params), do: socket
end
```

### EventHandlers

`TymeslotWeb.Themes.Shared.EventHandlers` handles common UI events using a callback pattern for flexibility:

```elixir
# Language and dropdown events
@impl Phoenix.LiveView
def handle_event("toggle_language_dropdown", _params, socket) do
  EventHandlers.handle_toggle_language_dropdown(socket)
end

@impl Phoenix.LiveView
def handle_event("change_locale", %{"locale" => locale}, socket) do
  EventHandlers.handle_change_locale(socket, locale, PathHandlers)
end

# Step-specific events using callback pattern
defp handle_overview_events(socket, event, data) do
  callbacks = %{
    maybe_assign_meeting_type: &maybe_assign_meeting_type/2,
    validate_state_transition: &validate_state_transition/3,
    transition_to: &transition_to/3
  }

  EventHandlers.handle_overview_events(socket, event, data, callbacks)
end

defp handle_state_transition(socket, current_state, next_state) do
  callbacks = %{
    validate_state_transition: &validate_state_transition/3,
    transition_to: &transition_to/3
  }

  EventHandlers.handle_state_transition(socket, current_state, next_state, callbacks)
end
```

**Key EventHandler Functions**:
- `handle_toggle_language_dropdown/1` - Toggle language selector
- `handle_close_language_dropdown/1` - Close language dropdown
- `handle_change_locale/3` - Change user locale
- `handle_overview_events/4` - Overview step events (duration selection, navigation)
- `handle_state_transition/4` - Navigate between steps
- `handle_timezone_events/4` - Timezone selection and search
- `handle_timezone_search/2` - Filter timezone list

### InfoHandlers

`TymeslotWeb.Themes.Shared.InfoHandlers` handles async tasks like availability fetching:

```elixir
@impl Phoenix.LiveView
def handle_info({:fetch_available_slots, date, duration, timezone}, socket) do
  InfoHandlers.handle_fetch_available_slots(socket, date, duration, timezone)
end

@impl Phoenix.LiveView
def handle_info({:load_slots, date}, socket) do
  InfoHandlers.handle_load_slots(socket, date)
end

# Handle month availability fetch completion (success)
@impl Phoenix.LiveView
def handle_info({ref, {:ok, availability_map}}, socket) when is_reference(ref) do
  InfoHandlers.handle_availability_ok(socket, ref, availability_map)
end

# Handle month availability fetch completion (error)
@impl Phoenix.LiveView
def handle_info({ref, {:error, reason}}, socket) when is_reference(ref) do
  InfoHandlers.handle_availability_error(socket, ref, reason)
end

# Handle task crash or timeout
@impl Phoenix.LiveView
def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
  InfoHandlers.handle_availability_down(socket, ref, reason)
end

@impl Phoenix.LiveView
def handle_info(:close_dropdown, socket) do
  InfoHandlers.handle_close_dropdown(socket)
end
```

**Key InfoHandler Functions**:
- `handle_fetch_available_slots/4` - Fetch available time slots for a date
- `handle_load_slots/2` - Load slots for date selection
- `handle_availability_ok/3` - Process successful availability fetch
- `handle_availability_error/3` - Handle availability fetch errors
- `handle_availability_down/3` - Handle task crashes/timeouts
- `handle_close_dropdown/1` - Close dropdowns after delay

### SchedulingInit

`TymeslotWeb.Themes.Shared.SchedulingInit` provides two initialization helpers:

**`assign_theme_state/2`** — preferred for theme LiveViews. Initializes all scheduling state in one call:

```elixir
defp assign_initial_state(socket) do
  socket
  |> SchedulingInit.assign_theme_state("3")
  # ... any theme-specific extras beyond what assign_theme_state covers
end
```

**`assign_base_state/1`** — lower-level; sets only the core socket fields shared across all flows. Use when you need fine-grained control or are not in a full scheduling context.

**Assigns from `assign_theme_state/2`** (superset of `assign_base_state/1`):
- `:theme_id` - Active theme ID
- `:duration`, `:meeting_type` - nil until selected
- `:current_year`, `:current_month` - today's values (UTC)
- `:current_week_start` - start of the current week (Monday-anchored, UTC)
- `:month_availability_map`, `:availability_status`, `:availability_task`, `:availability_task_ref`
- `:form`, `:touched_fields`, `:validation_errors`, `:saving` - booking form state
- `:client_ip`, `:submission_token`, `:meeting_types`
- Plus all assigns from `assign_base_state/1` below

**Assigns from `assign_base_state/1`**:
- `:current_state` - Current step in the flow
- `:username_context`, `:organizer_profile`, `:organizer_user_id`
- `:selected_duration`, `:selected_date`, `:selected_time`
- `:available_slots`, `:loading_slots`, `:calendar_error`
- `:timezone_dropdown_open`, `:timezone_search`
- `:reschedule_meeting_uid`, `:is_rescheduling`, `:meeting_uid`
- `:name`, `:email`, `:submitting`, `:submission_processed`

### BookingFlow

`TymeslotWeb.Themes.Shared.BookingFlow` handles form validation and submission:

```elixir
defp handle_booking_events(socket, event, data) do
  case event do
    :validate ->
      BookingFlow.handle_form_validation(socket, data)

    :submit ->
      BookingFlow.submit_booking(socket, data, &transition_to/3)

    :field_blur ->
      {:noreply, Helpers.mark_field_touched(socket, data)}

    :back_step ->
      handle_state_transition(socket, :booking, :schedule)
  end
end
```

**Key BookingFlow Functions**:
- `handle_form_validation/2` - Validate form fields in real-time
- `submit_booking/3` - Submit booking and transition to confirmation
- Both functions handle spam prevention, rate limiting, and error handling automatically

**Per-field inline errors**: Errors are shown per-field using `FormValidationHelpers.field_errors/2`, matching the pattern used by auth and contact forms. Each `.input` in the booking component must pass errors explicitly:

```heex
<.input
  field={f[:name]}
  errors={FormValidationHelpers.field_errors(@validation_errors, :name)}
  ...
/>
```

Errors only appear for fields the user has blurred (`touched_fields` MapSet), and clear automatically when the user corrects the input (validation returns `{:ok, ...}` → `validation_errors` becomes `%{}`).

Each booking input must also include `phx-debounce="blur"` alongside `phx-blur="field_blur"`. The debounce suppresses the `phx-change` event until the field loses focus; the blur event triggers per-field validation. Without the debounce, every keystroke fires a server round-trip:

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

## CSS Architecture

Themes use a **modular CSS architecture** located in `assets/css/scheduling/themes/`.

### Shared Primitives
- `assets/css/scheduling/shared/reset.css` — CSS reset
- `assets/css/scheduling/shared/layout.css` — Border-radius scale, Tailwind import, display/flex/grid helpers
- `assets/css/scheduling/shared/utilities.css` — Shared utility classes

Only structural primitives are shared. All visual components (colors, spacing, typography, buttons) stay per-theme even if currently identical — themes can diverge without fear.

### Theme Structure
Each theme has a `theme.css` entry point and a flat `modules/` subdirectory. Each component file is self-contained — it owns base styles, container queries, and iframe overrides in one place. No separate `responsive.css` or `embedded.css`.

## Theme Customization & Capabilities

Themes define their capabilities in the `Tymeslot.Themes.Catalog` `features` map, which are then used by the `Tymeslot.ThemeCustomizations.Capability` module to provide valid customization options.

### Supported Features
- `supports_video_background`
- `supports_image_background`
- `supports_gradient_background`
- `supports_custom_colors`

The capability system automatically generates the necessary CSS variables based on these flags and user selections.

## Meeting Management Integration

Each theme must implement `render_meeting_action/2` to provide its own UI for:
- `:reschedule`
- `:cancel`
- `:cancel_confirmed`

These components should reside in `lib/tymeslot_web/themes/[theme_name]/meeting/`.

## Common Patterns

### Modular LiveView Architecture

Modern themes follow a layered architecture that keeps the LiveView thin and maintainable:

#### 1. **SchedulingLive Macro**

All common LiveView callbacks are provided by the shared macro — no per-theme boilerplate needed:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Live do
  use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "3"

  alias TymeslotWeb.Themes.Aurora.Scheduling.Components.{
    BookingComponent, ConfirmationComponent, OverviewComponent, ScheduleComponent
  }
  alias TymeslotWeb.Themes.Aurora.Scheduling.Wrapper, as: AuroraThemeWrapper

  # Only override if your theme needs extra events (e.g. month navigation for calendar themes)
  # defp handle_theme_event(event, params, socket), do: {:noreply, socket}
  # defp handle_theme_schedule_event(socket, event, data), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <AuroraThemeWrapper.aurora_wrapper ...>
      ...
    </AuroraThemeWrapper.aurora_wrapper>
    """
  end
end
```

The macro injects `mount/3`, `handle_params/3`, all `handle_info/2` clauses, and `handle_event/3` handlers for language, booking, and scheduling events. Extension points `handle_theme_event/3` and `handle_theme_schedule_event/3` are `defoverridable` — implement them only if you need theme-specific events (e.g. month navigation for a full-calendar theme like Quill).

State machine logic (initial state, transition validation, navigation guards) lives in the shared `StateMachineHelpers` module — no per-theme StateMachine module is required.

#### 2. **Legacy: Per-Theme StateMachine Module**

> **Deprecated** — do not create new per-theme `state_machine.ex` files. The shared `StateMachineHelpers` covers all standard transitions. If you need custom transition validation, override `handle_theme_event/3` in your LiveView instead.

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
  def can_navigate_to_step?(socket, target_state) do
    # Only allow navigation to previous or current steps
    current_step = get_step_number(socket.assigns[:current_state])
    target_step = get_step_number(target_state)
    target_step <= current_step
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

The wrapper provides the theme's visual shell (background, language switcher, branding):

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Wrapper do
  use Phoenix.Component

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]
  import TymeslotWeb.Components.LanguageSwitcher

  attr :theme_customization, :map, default: nil
  attr :custom_css, :string, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  slot :inner_block, required: true

  def aurora_wrapper(assigns) do
    # Derives @has_video_background, @video_poster, @show_language_switcher
    assigns = prepare_wrapper_assigns(assigns)

    ~H"""
    <div class="aurora-theme-wrapper theme-3" data-locale={assigns[:locale]}>
      <%= if assigns[:custom_css] && assigns[:custom_css] != "" do %>
        <style type="text/css">
          :root {
            <%= Phoenix.HTML.raw(@custom_css) %>
          }
        </style>
      <% end %>

      <%= if @has_video_background do %>
        <div class="video-background">
          <video autoplay muted loop playsinline preload="metadata" poster={@video_poster}>
            <.video_sources theme_customization={@theme_customization} />
          </video>
        </div>
      <% end %>

      <div
        class="aurora-content"
        style={
          if assigns[:theme_customization] && !@has_video_background,
            do: get_background_style(assigns[:theme_customization]),
            else: ""
        }
      >
        <%= if assigns[:locale] && assigns[:language_dropdown_open] != nil do %>
          <.language_switcher
            locale={@locale}
            locales={TymeslotWeb.Themes.Shared.LocaleHandler.get_locales_with_metadata()}
            dropdown_open={@language_dropdown_open}
            theme="aurora"
          />
        <% end %>

        {render_slot(@inner_block)}

        {TymeslotWeb.Layouts.render_theme_extensions(assigns)}
      </div>
    </div>
    """
  end
end
```

Notes on the real pattern (matching Quill and Rhythm):
- The language switcher comes from `TymeslotWeb.Components.LanguageSwitcher`, **not**
  `CoreComponents`, and its `theme` attr is a **string** (`"aurora"`), not an atom.
- `custom_css` arrives as a ready-to-emit assign — render it inside a `:root { … }`
  `<style>` block; do not generate it in the wrapper.
- `organizer_user_id` is an **integer**.
- `render_theme_extensions/1` (from `TymeslotWeb.Layouts`) renders the branding
  footer and any embedded-mode extensions — call it instead of hand-rolling a
  "Powered by Tymeslot" footer.

#### 4. **Step Components**

Each step is a separate LiveComponent:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Components.OverviewComponent do
  use TymeslotWeb, :live_component

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="overview-step">
      <h1>Select Meeting Duration</h1>
      <div class="meeting-types">
        <%= for mt <- @meeting_types do %>
          <button
            phx-click="step_event"
            phx-value-step="overview"
            phx-value-event="select_duration"
            phx-value-data={mt.duration}
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

#### 5. **Shared Modules**

Leverage shared modules to avoid duplication:

- **SchedulingLive** (macro): All LiveView callbacks — `use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "N"`
- **SchedulingInit**: Base state initialization
- **BookingFlow**: Form validation and submission
- **EventHandlers**: Common event handling with callbacks
- **InfoHandlers**: Async task handling (availability fetching)
- **LocalizationHelpers**: Date/time formatting
- **PathHandlers**: Navigation with locale preservation
- **VideoSources**: `<.video_sources theme_customization={...} />` — video `<source>` elements for wrapper components
- **MeetingDetails**: `<.meeting_detail_rows date={...} time={...} timezone={...} organizer_name={...} />` — shared cancel/reschedule row layout

#### 6. **Event Communication Pattern**

Components send events to the LiveView using a standardized pattern:

```elixir
# In component template
<button phx-click="step_event" phx-value-step="overview" phx-value-event="select_duration" phx-value-data={duration}>

# In LiveView
@impl Phoenix.LiveView
def handle_info({:step_event, step, event, data}, socket) do
  case step do
    :overview -> handle_overview_events(socket, event, data)
    :schedule -> handle_schedule_events(socket, event, data)
    :booking -> handle_booking_events(socket, event, data)
    :confirmation -> handle_confirmation_events(socket, event, data)
  end
end
```

### Theme Template Rendering

The LiveView's `render/1` function delegates to the wrapper and components:

```elixir
@impl Phoenix.LiveView
def render(assigns) do
  # organizer_user_id is already set during mount by Scheduling.Helpers
  ~H"""
  <AuroraWrapper.aurora_wrapper
    custom_css={assigns[:custom_css]}
    theme_customization={assigns[:theme_customization]}
    locale={assigns[:locale]}
    language_dropdown_open={assigns[:language_dropdown_open]}
    current_state={assigns[:current_state]}
    organizer_user_id={@organizer_user_id}
    should_show_branding={assigns[:should_show_branding]}
  >
    <%= if assigns[:scheduling_error_message] do %>
      <.live_component
        module={ErrorComponent}
        id="scheduling-error"
        message={@scheduling_error_message}
        reason={assigns[:scheduling_error_reason]}
      />
    <% else %>
      <%= case assigns[:current_state] || :overview do %>
        <% :overview -> %>
          <.live_component module={OverviewComponent} id="overview-step" {assigns} />
        <% :schedule -> %>
          <.live_component module={ScheduleComponent} id="schedule-step" {assigns} />
        <% :questions -> %>
          <.live_component module={CustomQuestionsComponent} id="questions-step" {assigns} />
        <% :booking -> %>
          <.live_component module={BookingComponent} id="booking-step" {assigns} />
        <% :awaiting_payment -> %>
          <AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />
        <% :confirmation -> %>
          <.live_component module={ConfirmationComponent} id="confirmation-step" {assigns} />
        <% _ -> %>
          <.live_component module={OverviewComponent} id="overview-step" {assigns} />
      <% end %>
    <% end %>
  </AuroraWrapper.aurora_wrapper>
  """
end
```

Your `render/1` must handle all states the shared state machine can produce, not
just the four core steps:
- **`:questions`** — the custom-questions step, inserted between `:schedule` and
  `:booking` **only when the meeting type has custom fields** (see
  `StateMachineHelpers.states_for/1`). Render your theme's `CustomQuestionsComponent`.
- **`:awaiting_payment`** — a transitional state for paid embedded bookings while
  Stripe Checkout is open in another tab. Render the shared
  `AwaitingPayment.awaiting_payment/1` component.
- **`_` fallback** — render the overview as a safe default.

Both `CustomQuestionsComponent` (your theme's) and `AwaitingPayment` (shared, aliased
as `TymeslotWeb.Themes.Shared.Components.AwaitingPayment`) must be aliased in your
LiveView.

## Theme Customization System

### Background Options

Themes can offer users four types of backgrounds:

1. **Gradients** - CSS gradients defined in `ThemeCustomizationSchema.gradient_presets/0`
2. **Solid Colors** - User-selected hex colors
3. **Preset Images/Videos** - Pre-defined options stored in `/priv/static/`
4. **Custom Uploads** - User-uploaded images or videos

### Preset Assets Structure

Preset assets are organized in the static directory:

```
priv/static/
├── images/ui/backgrounds/       # Preset background images
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
    └── rhythm-background-poster.webp
```

### Defining Presets

Presets are defined in `database_schemas/theme_customization_schema.ex`.

**Available Video Presets**:
- `"preset:rhythm-default"`
- `"preset:blue-wave"`
- `"preset:dancing-girl"`
- `"preset:leaves"`
- `"preset:light-green"`
- `"preset:space"`

**Available Image Presets**:
- `"preset:artistic-studio"`
- `"preset:ocean-sunset"`
- `"preset:elegant-still-life"`

## Advanced Video Features

### Video Container Rendering

For themes with video backgrounds, use the `VideoSources` shared component to render `<source>` elements inside your video container. Import it in your wrapper:

```elixir
import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]
```

Then use it in your wrapper template:

```heex
<div class="your-video-container">
  <video autoplay muted loop playsinline>
    <.video_sources theme_customization={@theme_customization} />
  </video>
</div>
```

The component handles both user-uploaded videos and preset videos automatically, selecting the correct source paths and falling back to nothing if no video is configured.

For full video container rendering with crossfade and loading fallbacks, you can still use `TymeslotWeb.Themes.Shared.Customization.Video` directly:

```elixir
alias TymeslotWeb.Themes.Shared.Customization.Video

# In your theme wrapper
<div class="video-container">
  <%= Video.render_video_container(@theme_key, assigns) %>
</div>
```

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

### Language Switcher Integration

The language switcher is typically integrated via the theme's wrapper:

```heex
<.language_switcher
  locale={@locale}
  locales={TymeslotWeb.Themes.Shared.LocaleHandler.get_locales_with_metadata()}
  dropdown_open={@language_dropdown_open}
  theme={@theme_key}
/>
```

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

1. **Copy an existing theme** (Quill or Rhythm) as a starting point
2. **Register the theme** — add facts to `Tymeslot.Themes.Catalog` and bindings to `TymeslotWeb.Themes.Core.Registry`
3. **Rename files and modules** to match your theme name
4. **Create `live.ex`** with `use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "N"` — no per-theme StateMachine needed
5. **Update the Wrapper** with your theme's visual design; use `<.video_sources .../>` for video backgrounds
6. **Modify step components** (overview, schedule, custom_questions, booking, confirmation)
7. **Create CSS modules** in `assets/css/scheduling/themes/your-theme/`; import `../../shared/utilities.css` in your theme.css
8. **Implement meeting actions** (reschedule, cancel, cancel_confirmed); use `<.meeting_detail_rows .../>` for the detail layout
9. **Test with production checklist**

### What to Copy vs. What to Customize

**Don't copy at all** — the shared macro provides this automatically:
- `use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "N"` replaces all LiveView event handlers, state init, and shared module wiring
- No per-theme `state_machine.ex` — `StateMachineHelpers` is shared

**Customize** (theme-specific):
- `render/1` — wrapper component and step layout
- `handle_theme_event/3` override — only if your theme has unique events (e.g. Quill's `navigate_to_step`)
- `handle_theme_schedule_event/3` override — only if your theme has calendar month navigation
- Wrapper component layout and design
- Step component templates and styles
- CSS modules and variables
- Meeting action component designs (use `<.meeting_detail_rows .../>` for the rows)

**Do not re-derive in `render/1`** (already in socket assigns):
- `organizer_user_id` — set during mount by `SchedulingInit.assign_base_state/1` via `Scheduling.Helpers`. Do not extract it from `organizer_profile` in `render/1`; read `@organizer_user_id` directly.

### Testing Your Theme

Run the production checklist to validate your theme:

```bash
# Test all registered themes
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs

# Or test a specific theme
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs -t theme_id:3
```

The checklist automatically verifies:
- Theme renders without crashing
- All meeting types display correctly
- Edge cases work (no meetings, long names, etc.)
- Basic mobile responsiveness
- Acceptable load times
- State transitions function properly

### Debugging Tips

**Common Issues**:

1. **Component not found**: Check aliases in theme module match component names
2. **CSS not loading**: Verify `theme.css` imports all modules in correct order
3. **State transitions broken**: Check `StateMachineHelpers.validate_state_transition/3`, or your `handle_theme_event/3` override if you customised transitions
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
✅ **Implement all required callbacks** - Theme behaviour defines the contract
✅ **Keep LiveView thin** - It should hold little beyond `render/1`; delegate to the wrapper and components
✅ **Use LocalizationHelpers** - For all date/time formatting
✅ **Test with production checklist** - Automated validation catches issues early
✅ **Copy existing themes** - Rhythm and Quill are proven implementations

### Don'ts

❌ **Don't hardcode dates/times** - Always use LocalizationHelpers
❌ **Don't create a per-theme StateMachine** - `StateMachineHelpers` owns transitions; override `handle_theme_event/3` for custom logic
❌ **Don't duplicate shared logic** - Use the Shared.* modules
❌ **Don't mix theme and app styles** - Keep theme CSS isolated
❌ **Don't forget meeting actions** - Reschedule, cancel, cancel_confirmed required
❌ **Don't over-engineer** - Start simple, add complexity only when needed

## Summary Checklist

Before considering your theme complete:

- [ ] Theme facts added to `Catalog`, bindings added to `Registry`
- [ ] Theme module implements all behaviour callbacks
- [ ] LiveView uses the `SchedulingLive` macro (no per-theme StateMachine)
- [ ] Wrapper component provides theme layout
- [ ] All 5 step components implemented (overview, schedule, custom_questions, booking, confirmation)
- [ ] `render/1` handles the conditional `:questions` and `:awaiting_payment` states plus a fallback
- [ ] Schedule component has weekly strip (mobile) + monthly grid (desktop) with `CalendarNavigation` boundary checks on all nav buttons
- [ ] All 3 meeting action components implemented
- [ ] CSS theme.css imports all required modules
- [ ] `modules/iframe.css` created with `[data-embedded]`-scoped iframe shell rules
- [ ] Container query context set on primary content container
- [ ] No responsive Tailwind classes (`sm:`, `md:`, `lg:`) in templates
- [ ] No external font imports (use system fonts or self-hosted)
- [ ] Production checklist tests pass
- [ ] Intrinsic responsiveness works at all sizes (no viewport breakpoints)
- [ ] Localization works for all supported languages
- [ ] Video/image backgrounds work (if supported)
- [ ] Theme customization renders correctly
- [ ] Embedded mode tested — iframe grows and shrinks with content; no internal scrollbar in unconstrained inline embeds