# Theme Development Guide

This guide explains how to create new themes for Tymeslot.

## Architecture Overview

The theme system uses a centralized registry pattern that eliminates magic strings and provides type-safe theme access.

### Key Components

1. **Theme Registry** (`Tymeslot.Themes.Registry`) - Central source of truth for all themes
2. **Theme Module** (`Tymeslot.Themes.Theme`) - Backward-compatible facade
3. **Shared Components** (`TymeslotWeb.Live.Scheduling.Themes.Shared.*`) - Optional reusable components
4. **Theme Customization** - User-configurable colors, backgrounds, and styles
5. **Preset Assets** - Pre-defined backgrounds (images/videos) that users can choose from

## Quick Start

### 1. Generate Theme Files (Preview)

```elixir
# This previews what files would be created (doesn't actually create them)
Tymeslot.ThemeTestHelpers.generate_theme_skeleton("aurora", "Aurora Theme")

# Copy the returned content to create your theme files manually
# The helper returns a map with file paths and their contents
```

### 2. Register Your Theme

Add to `lib/tymeslot/themes/registry.ex`:

```elixir
aurora: %{
  id: "3",
  key: :aurora,
  name: "Aurora", 
  description: "Beautiful northern lights theme",
  module: TymeslotWeb.Themes.AuroraTheme,
  css_file: "/assets/scheduling-theme-aurora.css",
  # ... other required fields
}
```

### 3. Implement Required Functions

Your theme module must implement these behaviors:

```elixir
defmodule TymeslotWeb.Themes.AuroraTheme do
  @behaviour TymeslotWeb.Themes.ThemeBehaviour
  
  # Define your theme states (typically 4 steps)
  def states do
    %{
      overview: %{step: 1, next: :calendar},
      calendar: %{step: 2, next: :booking_form, prev: :overview},
      booking_form: %{step: 3, next: :confirmation, prev: :calendar},
      confirmation: %{step: 4, prev: nil}
    }
  end
  
  def css_file, do: "/css/themes/scheduling-theme-aurora.css"
  def components, do: %{overview: AuroraOverviewComponent}
  def live_view_module, do: AuroraSchedulingLive
  def theme_config, do: %{name: "Aurora", description: "Beautiful theme"}
  def validate_theme, do: :ok
  def initial_state_for_action(_), do: :overview
  def supports_feature?(_), do: true
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

### New Modular Structure

Starting with the current codebase, themes now use a **modular CSS architecture** located in `assets/css/scheduling/themes/`:

```
assets/css/scheduling/themes/
├── shared/                    # Shared utilities
│   ├── reset.css             # CSS reset
│   ├── variables.css         # CSS custom properties
│   └── utilities.css         # Utility classes
├── quill/                     # Quill theme (glassmorphism)
│   ├── modules/
│   │   ├── foundation.css    # Base styles and typography
│   │   ├── glass-components.css # Glass morphism components
│   │   ├── scheduling-ui.css # Scheduling interface
│   │   ├── booking-flow.css  # Booking flow specific styles
│   │   └── responsive.css    # Responsive breakpoints
│   └── theme.css             # Main theme entry point
└── rhythm/                    # Rhythm theme (video backgrounds)
    ├── modules/
    │   ├── variables.css      # Theme-specific variables
    │   ├── base.css           # Base layout and typography
    │   ├── video.css          # Video background handling
    │   ├── slides.css         # Sliding interface
    │   ├── components.css     # UI components
    │   └── responsive.css     # Mobile responsive styles
    └── theme.css              # Main theme entry point
```

### Theme CSS Structure

Each theme's main CSS file (`theme.css`) follows this pattern:

```css
/* Import shared utilities */
@import "../../shared/reset.css";
@import "../../shared/variables.css";
@import "../../shared/utilities.css";

/* Import theme modules in dependency order */
@import "./modules/foundation.css";
@import "./modules/components.css";
@import "./modules/responsive.css";
```

### Creating Theme CSS

1. **Create theme directory**: `assets/css/scheduling/themes/your-theme/`
2. **Create main theme.css** that imports shared utilities and your modules
3. **Create modular CSS files** in a `modules/` subdirectory

**Note**: Theme CSS is completely separate from global app styles and uses only the modular architecture in `assets/css/scheduling/themes/`.

## Theme Requirements

### Must Have
- LiveView that renders without crashing
- CSS file in `assets/css/scheduling/themes/your-theme/theme.css`
- All 4 booking flow states: overview, calendar, booking_form, confirmation

### Nice to Have
- Mobile responsive design
- Smooth transitions
- Accessibility features

## Using Shared Components

The theme system provides optional shared components that you can use to speed up development:

### Theme Layout

```elixir
# In your theme component
import TymeslotWeb.Live.Scheduling.Themes.Shared.ThemeLayout

def render(assigns) do
  ~H"""
  <.theme_layout 
    theme_id={@theme_id}
    theme_customization={@theme_customization}
    custom_css={@custom_css}
  >
    <div class="my-theme-content">
      <!-- Your theme-specific content -->
    </div>
  </.theme_layout>
  """
end
```

### Theme Helpers

```elixir
# Import shared helpers
import TymeslotWeb.Live.Scheduling.Themes.Shared.ThemeHelpers

# Use helper functions
format_duration(30)  # "30 minutes"
format_date(date, :full)  # "Wednesday, March 15, 2024"
theme_supports?("1", :video_background)  # true
```

### Theme Assets

```elixir
# Optimized asset loading
alias TymeslotWeb.Themes.ThemeAssets

# Generate versioned URLs with caching
ThemeAssets.versioned_asset_url("/css/my-theme.css")

# Generate preload tags for performance
ThemeAssets.preload_tags(theme_id)

# Get theme CSS file path
ThemeAssets.theme_css_file(theme_id)

# Generate theme-specific asset paths
ThemeAssets.theme_asset_path(theme_id, "images/background.jpg")
```

The ThemeAssets module provides centralized asset management with:
- Versioning for cache busting
- Preload tag generation for performance
- Theme-specific asset path resolution
- Consistent asset URL handling

## Common Patterns

### Step Component Pattern (Recommended)

To keep theme modules small and maintainable, split your scheduling UI into step components and keep the LiveView thin. Each theme should implement:

- A LiveView that orchestrates states (overview, schedule, booking, confirmation)
- Separate components for each step
- Small handler modules for complex logic (e.g., state machine, booking flow)

Example mapping:

```elixir
%{
  overview: MyTheme.Scheduling.Components.OverviewComponent,
  schedule: MyTheme.Scheduling.Components.ScheduleComponent,
  booking: MyTheme.Scheduling.Components.BookingComponent,
  confirmation: MyTheme.Scheduling.Components.ConfirmationComponent
}
```

The LiveView decides which component to render based on @current_state; components emit events back via send(self(), {:step_event, step, event, data}).

### Simple Theme Structure

```elixir
# Minimal working theme (must have all 4 states)
defmodule SimpleTheme do
  def states do
    %{
      overview: %{step: 1, next: :calendar},
      calendar: %{step: 2, next: :booking_form, prev: :overview},
      booking_form: %{step: 3, next: :confirmation, prev: :calendar},
      confirmation: %{step: 4}
    }
  end
  
  def components do
    %{
      overview: SimpleOverviewComponent,
      calendar: SimpleCalendarComponent,
      booking_form: SimpleBookingFormComponent,
      confirmation: SimpleConfirmationComponent
    }
  end
  
  def live_view_module, do: SimpleSchedulingLive
  # ... other required callbacks
end
```

### LiveView Implementation

```elixir
defmodule SimpleSchedulingLive do
  use TymeslotWeb, :live_view
  
  def mount(params, _session, socket) do
    # Use existing helpers for data loading
    socket = assign_user_data(socket, params)
    {:ok, socket}
  end
  
  def render(assigns) do
    ~H"""
    <div class="simple-theme">
      <%= live_component(@components[@current_state], assigns) %>
    </div>
    """
  end
end
```

## Logic Extraction for Larger Themes

When logic grows, extract it into small, testable modules:

- State machine: TymeslotWeb.Themes.Quill.Scheduling.StateMachine
  - determine_initial_state/1
  - can_navigate_to_step?/2
  - validate_state_transition/3
- Booking flow: TymeslotWeb.Themes.Quill.Scheduling.BookingFlow
  - handle_form_validation/2
  - process_booking_submission/2 (accepts a transition function)

Keep the LiveView as the orchestrator (assigns and transitions), and components as pure UI wrappers that emit events.

## Theme Customization System

### Background Options

Themes can offer users three types of backgrounds:

1. **Gradients** - CSS gradients defined in code
2. **Preset Images/Videos** - Pre-defined options stored in `/priv/static/`
3. **Custom Uploads** - User-uploaded images or videos

### Preset Assets Structure

Preset assets are organized in the static directory:

```
priv/static/
├── images/themes/backgrounds/   # Preset background images
│   ├── light-green-thumbnail.jpg
│   ├── leaves-thumbnail.jpg
│   ├── blue-wave-thumbnail.jpg
│   ├── space-thumbnail.jpg
│   └── ...
└── videos/                      # Preset background videos
    ├── blue-wave-desktop.webm   # Desktop WebM (best quality)
    ├── blue-wave-desktop.mp4    # Desktop MP4 (fallback)
    ├── blue-wave-mobile.mp4     # Mobile optimized
    ├── blue-wave-low.mp4        # Low bandwidth
    ├── blue-wave-thumbnail.jpg  # Video thumbnail
    ├── dancing-girl-*           # Multi-quality variants
    ├── leaves-*                 # Multi-quality variants
    ├── light-green-*            # Multi-quality variants
    ├── space-*                  # Multi-quality variants
    └── rhythm-background-*      # Theme-specific videos
```

**Note**: Video assets now support multiple quality levels (desktop.webm, desktop.mp4, mobile.mp4, low.mp4) with thumbnails.

### Defining Presets

Presets are now defined in `database_schemas/theme_customization_schema.ex` with multi-quality video support.

### Storage Pattern

- **Presets**: Stored as `"preset:preset-name"` (e.g., `"preset:blue-wave"`, `"preset:rhythm-default"`, `"preset:leaves"`)
- **Custom Uploads**: Stored as file paths (e.g., `"/uploads/user123/bg.jpg"`)

This allows the system to distinguish between preset and custom backgrounds.

**Available Video Presets**:
- `"preset:rhythm-default"` - Default Rhythm theme video
- `"preset:blue-wave"` - Blue wave animation
- `"preset:dancing-girl"` - Dancing silhouette
- `"preset:leaves"` - Autumn leaves
- `"preset:light-green"` - Light green abstract
- `"preset:space"` - Space animation

### Theme Defaults

Set appropriate defaults for your theme:

```elixir
defp get_theme_defaults(theme_id) do
  case theme_id do
    "1" -> # Quill theme (glassmorphism)
      %{
        color_scheme: "default", 
        background_type: "gradient",
        background_value: "gradient_turquoise"
      }
    "2" -> # Rhythm theme (video backgrounds)
      %{
        color_scheme: "default",
        background_type: "video", 
        background_value: "preset:rhythm-default"  # Use actual preset names
      }
  end
end
```

## Meeting Management Theme Components

Themes can provide custom interfaces for meeting management operations (reschedule, cancel, etc.):

### Directory Structure

```
lib/tymeslot_web/live/meeting_management/themes/
├── quill/
│   ├── cancel_component.ex      # Cancellation UI for Quill theme
│   └── reschedule_component.ex  # Reschedule UI for Quill theme
└── rhythm/
    ├── cancel_component.ex      # Cancellation UI for Rhythm theme
    └── reschedule_component.ex  # Reschedule UI for Rhythm theme
```

### Implementation Example

```elixir
defmodule TymeslotWeb.Live.MeetingManagement.Themes.Quill.CancelComponent do
  use TymeslotWeb, :live_component
  
  def render(assigns) do
    ~H"""
    <div class="quill-cancel-container">
      <!-- Theme-specific cancellation UI -->
      <.button phx-click="cancel_meeting" class="quill-cancel-btn">
        Cancel Meeting
      </.button>
    </div>
    """
  end
end
```

### Using Theme Components in Meeting Management

The system automatically loads the appropriate theme component based on the user's selected theme:

```elixir
# In your meeting management LiveView
def get_theme_component(theme_id, action) do
  case {theme_id, action} do
    {"1", :cancel} -> TymeslotWeb.Live.MeetingManagement.Themes.Quill.CancelComponent
    {"2", :cancel} -> TymeslotWeb.Live.MeetingManagement.Themes.Rhythm.CancelComponent
    # ... other mappings
  end
end
```

## Advanced Video Features

### Video Crossfading

For themes with video backgrounds, the system supports smooth crossfading between multiple videos:

```elixir
# Using the video helpers for crossfading
alias TymeslotWeb.Themes.VideoHelpers

# Render crossfading video backgrounds
def render_crossfading_videos(assigns) do
  ~H"""
  <div class="video-container">
    <%= VideoHelpers.render_crossfading_videos(@video_urls, @current_index) %>
  </div>
  """
end

# Video helper functions available:
VideoHelpers.get_video_sources(video_preset)  # Get multi-quality sources
VideoHelpers.render_video_element(video_url, options)  # Render optimized video
VideoHelpers.supports_video_background?(theme_id)  # Check theme support
```

### Multi-Quality Video System

The video system automatically selects the best quality based on:
- Device type (desktop vs mobile)
- Connection speed
- Battery status
- Data saver preferences

```elixir
# Video quality variants (automatically handled)
%{
  desktop_webm: "/videos/backgrounds/theme-video-desktop.webm",  # Best quality
  desktop_mp4: "/videos/backgrounds/theme-video-desktop.mp4",    # Fallback
  mobile: "/videos/backgrounds/theme-video-mobile.mp4",          # Mobile optimized
  low: "/videos/backgrounds/theme-video-low.mp4",                # Low bandwidth
  thumbnail: "/videos/thumbnails/theme-video-thumbnail.jpg"     # Preview image
}
```

### Performance Optimizations

The video system includes built-in optimizations:
- **Lazy loading**: Videos load only when needed
- **Connection-aware**: Adapts to network conditions
- **Battery-conscious**: Pauses on low battery
- **Reduced motion**: Respects accessibility preferences
- **Preloading**: Strategic preloading for smooth transitions

## Error Handling & Rate Limiting

### File Upload Error Handling

The theme customization system includes comprehensive error handling:

```elixir
# Rate limiting for file uploads (5 uploads per 10 minutes)
case check_file_upload_rate_limit(user_id) do
  :ok -> process_upload(socket)
  {:error, :rate_limited} -> 
    put_flash(socket, :error, "Too many upload attempts. Please wait.")
end
```

### Error Messages

User-friendly error messages are provided for common issues:
- File too large (5MB for images, 50MB for videos)
- Invalid file type (only JPG, PNG, WebP for images; MP4, WebM for videos)
- Upload failures (disk space, permissions, etc.)

### Cleanup Considerations

When users switch between presets and custom uploads:
- Custom uploads should be cleaned up when replaced by presets
- Preset selections don't require cleanup (they're shared assets)
- Implement cleanup logic in background jobs to avoid blocking UI

### UI Implementation

The customization UI shows:

1. **Current Background Display** - Shows what's actually saved (not what's being edited)
2. **Background Type Selection** - Grid of options (Gradient, Color, Image, Video)
3. **Preset Grid** - Visual grid of available presets with:
   - Thumbnails/previews
   - Names and descriptions
   - Selection indicators
4. **Upload Section** - Separate area for custom uploads with:
   - Drag-and-drop file input
   - Upload progress
   - Warning when replacing existing uploads

Example UI structure:
```heex
<div class="space-y-6">
  <!-- Show preset options -->
  <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
    <%= for {preset_id, preset} <- @video_presets do %>
      <button phx-click="select_preset_video" phx-value-video={preset_id}>
        <!-- Preset preview -->
      </button>
    <% end %>
  </div>
  
  <!-- Divider -->
  <div class="relative">
    <span class="px-2 bg-white text-gray-500">Or upload your own</span>
  </div>
  
  <!-- Upload form -->
  <form phx-submit="save_background_video">
    <.live_file_input upload={@uploads.background_video} />
  </form>
</div>
```

## Debugging Tips

1. **Theme not loading?** Check it's registered in registry.ex
2. **Page crashes?** Check browser console and server logs
3. **CSS not applying?** Run `mix assets.deploy`
4. **Theme not in tests?** Ensure it's registered with status: :active
5. **Preset not showing?** Check:
   - Image files exist in `/priv/static/images/ui/backgrounds/`
   - Video files exist in `/priv/static/videos/backgrounds/` and thumbnails in `/priv/static/videos/thumbnails/`
   - Preset is defined in `database_schemas/theme_customization_schema.ex`
   - File names in preset definition match actual files
   - Video presets include all quality variants (desktop.webm, desktop.mp4, mobile.mp4, low.mp4, thumbnail.jpg)
6. **Custom upload failing?** Check:
   - File size limits (5MB images, 50MB videos)
   - File type restrictions
   - Disk space and permissions

## Production Readiness

Before releasing a theme, ensure it passes these checks:

1. **Meeting Types Display**: All active meeting types must be visible
2. **Edge Case Handling**: Works with no meetings, long names, etc.
3. **Error States**: Doesn't crash when data is missing
4. **Mobile Ready**: Has viewport meta tag and responsive design
5. **Performance**: Loads quickly (under 5 seconds in tests)

The production checklist test (`theme_production_checklist_test.exs`) verifies all of these automatically.

## Don't Over-Engineer

- Start with the simplest theme that works
- Copy from existing themes
- Focus on user experience, not code perfection
- The production checklist tells you if it's ready