# Theme Development Guide

This guide explains how to create new themes for Tymeslot.

## Architecture Overview

The theme system uses a centralized registry pattern that eliminates magic strings and provides type-safe theme access.

### Key Components

1. **Theme Registry** (`TymeslotWeb.Themes.Core.Registry`) - Central source of truth for all themes
2. **Theme Behaviour** (`TymeslotWeb.Themes.Core.Behaviour`) - Interface that all themes must implement
3. **Shared Context** (`TymeslotWeb.Themes.Shared.*`) - Shared helpers, handlers, and components
4. **Capability System** (`Tymeslot.ThemeCustomizations.Capability`) - Capability-based customization logic
5. **Dispatcher & Loader** (`TymeslotWeb.Themes.Core.Dispatcher`, `TymeslotWeb.Themes.Core.Loader`) - Systems for dynamically loading and dispatching theme actions
6. **Event Bus** (`TymeslotWeb.Themes.Core.EventBus`) - Centralized event handling system for theme components
7. **State Machine** (per-theme) - Validates state transitions and determines routing behavior
8. **Wrapper Components** (per-theme) - Provides theme-specific layout, backgrounds, and UI chrome

## Quick Reference

### File Structure for a Theme

```
lib/tymeslot_web/themes/[theme_name]/
├── theme.ex                    # Theme behaviour implementation
├── scheduling/
│   ├── live.ex                 # Main LiveView
│   ├── state_machine.ex        # State transition logic
│   ├── wrapper.ex              # Theme layout wrapper
│   └── components/
│       ├── overview_component.ex
│       ├── schedule_component.ex
│       ├── booking_component.ex
│       └── confirmation_component.ex
└── meeting/
    ├── reschedule.ex
    ├── cancel.ex
    └── cancel_confirmed.ex

assets/css/scheduling/themes/[theme_name]/
├── theme.css                   # Main entry point
└── modules/
    ├── variables.css           # Design tokens (colors, spacing, typography)
    ├── base.css                # html, body, theme wrapper, root grid
    ├── iframe.css              # Iframe shell rules (~30 lines)
    ├── typography.css          # Text styles with fluid clamp() sizes
    ├── video.css               # Video background (if supported)
    ├── overview.css            # Organizer profile + avatar (if theme has distinct overview)
    ├── calendar.css            # Calendar grid + container queries
    ├── time-slots.css          # Time slot grid + container queries
    ├── schedule-header.css     # Schedule header + timezone selector
    ├── booking.css             # Booking form + container queries
    ├── confirmation.css        # Confirmation + container queries
    ├── components.css          # Buttons, inputs, duration cards, glassmorphism
    └── language-switcher.css   # Language switcher
```

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
| `LocalizationHelpers` | Date/time/duration formatting: `format_date/1`, `format_duration/1`, `format_booking_datetime/3`, `format_time_by_locale/1` (respects locale 12h/24h setting — always use this for time slot display), `day_name_short/1` (localized weekday abbreviations), `get_week_display/1` (formatted week range string), `sort_meeting_types/1` (natural sort — use in `update/2` for consistent ordering) |
| `Tymeslot.Timezones` | Human-readable timezone display: `Timezones.format/1` — use this in confirmation and booking components instead of string-splitting the IANA timezone identifier |
| `Scheduling.Helpers` | Calendar/week day generation (`get_week_days/4` — pass `@user_timezone`), week navigation (`handle_week_navigation/2`), availability fetching, slot parsing, `display_range/2` for visible date boundaries |
| `Scheduling.CalendarNavigation` | Navigation boundary checks: `prev_month_disabled?/3`, `next_month_disabled?/4` (pass `@organizer_profile.advance_booking_days`), `prev_week_disabled?/2`, `next_week_disabled?/3` (pass `advance_booking_days`) — wire these to nav button `disabled` attributes |
| `PathHandlers` | Navigation with locale preservation |
| `Customization.Helpers` | Theme customization CSS generation |
| `Customization.Video` | Video background rendering |

## Quick Start

### 1. Create Theme Directory Structure

Create the following directory structure for your new theme:

```
apps/tymeslot/lib/tymeslot_web/themes/aurora/
├── scheduling/
│   ├── components/
│   │   ├── booking_component.ex
│   │   ├── confirmation_component.ex
│   │   ├── overview_component.ex
│   │   └── schedule_component.ex
│   ├── live.ex
│   ├── state_machine.ex
│   └── wrapper.ex
├── meeting/
│   ├── cancel.ex
│   ├── cancel_confirmed.ex
│   └── reschedule.ex
└── theme.ex

apps/tymeslot/assets/css/scheduling/themes/aurora/
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
│   ├── booking.css             # Booking form + container queries
│   ├── confirmation.css        # Confirmation step
│   ├── components.css          # Buttons, inputs, duration cards
│   └── language-switcher.css   # Language dropdown
└── theme.css
```

**Tip**: Copy an existing theme (Quill or Rhythm) as a starting point and modify it.

### 2. Register Your Theme

Add to `apps/tymeslot/lib/tymeslot_web/themes/core/registry.ex`:

```elixir
aurora: %{
  id: "3",
  key: :aurora,
  name: "Aurora", 
  description: "Beautiful northern lights theme",
  module: TymeslotWeb.Themes.Aurora.Theme,
  css_file: "/assets/scheduling-theme-aurora.css",
  preview_image: "/images/themes/aurora-preview.png",
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

Themes use a **modular CSS architecture** located in `apps/tymeslot/assets/css/scheduling/themes/`:

```
apps/tymeslot/assets/css/scheduling/themes/
├── shared/                        # Shared structural primitives only
│   ├── reset.css                 # CSS reset
│   └── layout.css                # Border-radius scale, Tailwind import, display helpers
├── quill/                         # Quill theme (glassmorphism)
│   ├── modules/
│   │   ├── variables.css         # Design tokens
│   │   ├── base.css              # Root layout, theme wrapper
│   │   ├── iframe.css            # Iframe shell rules
│   │   ├── video.css             # Video background
│   │   ├── typography.css        # Text styles
│   │   ├── overview.css          # Organizer profile
│   │   ├── calendar.css          # Calendar + container queries
│   │   ├── time-slots.css        # Time slots + container queries
│   │   ├── schedule-header.css   # Schedule header + timezone
│   │   ├── booking.css           # Booking form
│   │   ├── confirmation.css      # Confirmation step
│   │   ├── components.css        # UI components + glassmorphism
│   │   └── language-switcher.css # Language dropdown
│   └── theme.css                 # Entry point
└── rhythm/                        # Rhythm theme (video backgrounds)
    ├── modules/
    │   ├── variables.css
    │   ├── base.css
    │   ├── iframe.css
    │   ├── video.css
    │   ├── typography.css
    │   ├── overview.css
    │   ├── calendar.css
    │   ├── time-slots.css
    │   ├── schedule-header.css
    │   ├── booking.css
    │   ├── confirmation.css
    │   ├── components.css
    │   └── language-switcher.css
    └── theme.css
```

### Theme CSS Structure

Each theme's main CSS file (`theme.css`) imports shared primitives then theme modules:

```css
/* Import shared structural primitives */
@import "../../shared/reset.css";
@import "../../shared/layout.css";

/* Import theme modules */
@import "./modules/variables.css";
@import "./modules/base.css";
@import "./modules/iframe.css";
@import "./modules/video.css";
@import "./modules/typography.css";
@import "./modules/components.css";
@import "./modules/schedule-header.css";
@import "./modules/calendar.css";
@import "./modules/time-slots.css";
@import "./modules/booking.css";
@import "./modules/overview.css";
@import "./modules/confirmation.css";
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

Only data utilities are shared across themes (`TymeslotWeb.Components.MeetingUtils`):
- `normalize_slot_list/1` — normalizes time slot data
- `normalize_slot_time/1` — normalizes time format

All UI components (duration cards, calendar day buttons, time slot buttons, etc.) are theme-owned. Each theme renders its own markup and styles it with its own CSS.

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

### Creating Theme CSS

1. **Create theme directory**: `apps/tymeslot/assets/css/scheduling/themes/your-theme/`
2. **Create main theme.css** that imports shared primitives and your modules
3. **Create modular CSS files** in a `modules/` subdirectory — each component file is self-contained
4. **Set container query context** on the primary content container (`container-type: inline-size; container-name: scheduling;`)
5. **No external font imports** — use system font stacks or self-hosted fonts only

**Note**: Theme CSS is completely separate from global app styles.

## Theme Requirements

### Must Have
- Theme module implementing `TymeslotWeb.Themes.Core.Behaviour`
- LiveView module that renders without crashing
- StateMachine module for state transitions
- Wrapper component for theme layout
- CSS file in `apps/tymeslot/assets/css/scheduling/themes/your-theme/theme.css`
- `modules/iframe.css` with `[data-embedded]`-scoped iframe shell rules
- Container query context (`container-type: inline-size`) on the primary content container
- All 4 booking flow states: **overview**, **schedule**, **booking**, **confirmation**
- All 4 step components as LiveComponents
- Schedule component must include both the weekly strip (mobile) and monthly grid (desktop) with nav buttons wired to `CalendarNavigation` boundary checks
- Meeting action components (reschedule, cancel, cancel_confirmed)

### Nice to Have
- Smooth transitions
- Accessibility features

## Using Shared Logic and Helpers

The theme system provides centralized handlers and helpers in `TymeslotWeb.Themes.Shared.*` to ensure consistency and reduce duplication.

### LiveHelpers

`TymeslotWeb.Themes.Shared.LiveHelpers` provides common mounting and parameter handling logic:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Live do
  use TymeslotWeb, :live_view
  require Logger

  alias TymeslotWeb.Themes.Aurora.Scheduling.StateMachine
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

Only structural primitives are shared. All visual components (colors, spacing, typography, buttons) stay per-theme even if currently identical — themes can diverge without fear.

### Theme Structure
Each theme has a `theme.css` entry point and a flat `modules/` subdirectory. Each component file is self-contained — it owns base styles, container queries, and iframe overrides in one place. No separate `responsive.css` or `embedded.css`.

## Theme Customization & Capabilities

Themes define their capabilities in the registry, which are then used by the `Tymeslot.ThemeCustomizations.Capability` module to provide valid customization options.

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

#### 1. **StateMachine Module**

Each theme has its own `StateMachine` module (`themes/[theme_name]/scheduling/state_machine.ex`) that handles:

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

#### 2. **Wrapper Component**

The wrapper provides the theme's visual shell (background, language switcher, branding):

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Wrapper do
  use Phoenix.Component

  import TymeslotWeb.CoreComponents, only: [language_switcher: 1]

  alias TymeslotWeb.Themes.Shared.Customization.{Helpers, Video}
  alias TymeslotWeb.Themes.Shared.LocaleHandler

  attr :custom_css, :string, default: nil
  attr :theme_customization, :map, default: nil
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true
  attr :current_state, :atom, required: true
  attr :organizer_user_id, :string, default: nil
  attr :should_show_branding, :boolean, default: true

  slot :inner_block, required: true

  def aurora_wrapper(assigns) do
    custom_css = Helpers.generate_custom_css(:aurora, assigns.theme_customization)
    assigns = assign(assigns, :generated_css, custom_css)

    ~H"""
    <div class="aurora-theme-container" style={@generated_css}>
      <!-- Video background (if supported) -->
      <%= if @theme_customization do %>
        <%= Video.render_video_container(:aurora, assigns) %>
      <% end %>

      <!-- Language switcher -->
      <.language_switcher
        locale={@locale}
        locales={LocaleHandler.get_locales_with_metadata()}
        dropdown_open={@language_dropdown_open}
        theme={:aurora}
      />

      <!-- Main content -->
      <div class="aurora-content">
        <%= render_slot(@inner_block) %>
      </div>

      <!-- Branding footer -->
      <%= if @should_show_branding do %>
        <div class="branding-footer">
          Powered by Tymeslot
        </div>
      <% end %>
    </div>
    """
  end
end
```

#### 3. **Step Components**

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

#### 4. **Shared Modules**

Leverage shared modules to avoid duplication:

- **SchedulingInit**: Base state initialization
- **BookingFlow**: Form validation and submission
- **EventHandlers**: Common event handling with callbacks
- **InfoHandlers**: Async task handling (availability fetching)
- **LocalizationHelpers**: Date/time formatting
- **PathHandlers**: Navigation with locale preservation

#### 5. **Event Communication Pattern**

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
  organizer_user_id =
    case assigns[:organizer_profile] do
      %{user_id: user_id} -> user_id
      _other -> nil
    end

  assigns = assign(assigns, :organizer_user_id, organizer_user_id)

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
        <% :booking -> %>
          <.live_component module={BookingComponent} id="booking-step" {assigns} />
        <% :confirmation -> %>
          <.live_component module={ConfirmationComponent} id="confirmation-step" {assigns} />
      <% end %>
    <% end %>
  </AuroraWrapper.aurora_wrapper>
  """
end
```

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

For themes with video backgrounds, use `TymeslotWeb.Themes.Shared.Customization.Video` to render an optimized video container:

```elixir
alias TymeslotWeb.Themes.Shared.Customization.Video

# In your theme wrapper
<div class="video-container">
  <%= Video.render_video_container(@theme_key, assigns) %>
</div>
```

This helper automatically handles:
- **Responsive Sources**: Loading different qualities based on screen size
- **Crossfading**: Smooth transitions for themes that support it
- **Fallbacks**: Displaying a gradient while the video is loading

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
2. **Update the registry** with your theme metadata
3. **Rename files and modules** to match your theme name
4. **Customize the StateMachine** if you need different validation logic
5. **Update the Wrapper** with your theme's visual design
6. **Modify step components** (overview, schedule, booking, confirmation)
7. **Create CSS modules** in `assets/css/scheduling/themes/your-theme/`
8. **Implement meeting actions** (reschedule, cancel, cancel_confirmed)
9. **Test with production checklist**

### What to Copy vs. What to Customize

**Copy as-is** (shared logic, rarely changes):
- LiveView event handlers (`handle_info`, `handle_event`)
- State initialization helpers
- Shared module usage (LiveHelpers, EventHandlers, etc.)

**Customize** (theme-specific):
- StateMachine validation rules
- Wrapper component layout and design
- Step component templates and styles
- CSS modules and variables
- Meeting action component designs

### Testing Your Theme

Run the production checklist to validate your theme:

```bash
# Test all registered themes
mix test apps/tymeslot/test/tymeslot_web/live/themes/theme_production_checklist_test.exs

# Or test a specific theme
mix test apps/tymeslot/test/tymeslot_web/live/themes/theme_production_checklist_test.exs -t theme_id:3
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
3. **State transitions broken**: Check StateMachine validation logic
4. **Availability not loading**: Ensure InfoHandlers are implemented
5. **Form submission fails**: Check BookingFlow integration

**Debug helpers**:

```elixir
# In LiveView mount or handle_info
require Logger
Logger.debug("Socket assigns: #{inspect(socket.assigns)}")

# In StateMachine
def validate_state_transition(socket, current, next) do
  Logger.info("Transition: #{current} -> #{next}")
  # validation logic
end
```

## Best Practices

### Do's

✅ **Use shared modules** - LiveHelpers, EventHandlers, InfoHandlers, BookingFlow
✅ **Follow the callback pattern** - EventHandlers use callbacks for flexibility
✅ **Implement all required callbacks** - Theme behaviour defines the contract
✅ **Keep LiveView thin** - Delegate to StateMachine, Wrapper, and components
✅ **Use LocalizationHelpers** - For all date/time formatting
✅ **Test with production checklist** - Automated validation catches issues early
✅ **Copy existing themes** - Rhythm and Quill are proven implementations

### Don'ts

❌ **Don't hardcode dates/times** - Always use LocalizationHelpers
❌ **Don't skip StateMachine validation** - It prevents invalid state transitions
❌ **Don't duplicate shared logic** - Use the Shared.* modules
❌ **Don't mix theme and app styles** - Keep theme CSS isolated
❌ **Don't forget meeting actions** - Reschedule, cancel, cancel_confirmed required
❌ **Don't over-engineer** - Start simple, add complexity only when needed

## Summary Checklist

Before considering your theme complete:

- [ ] Theme registered in `Registry.ex`
- [ ] Theme module implements all behaviour callbacks
- [ ] StateMachine module handles state transitions
- [ ] Wrapper component provides theme layout
- [ ] All 4 step components implemented (overview, schedule, booking, confirmation)
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
- [ ] Embedded mode tested at constrained and unconstrained heights