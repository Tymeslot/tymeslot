defmodule TymeslotWeb.OnboardingLive.LivePreview do
  @moduledoc """
  Live preview panel for the onboarding flow.

  Renders a miniature mock of the user's public booking page that updates
  reactively as the onboarding form is filled in. The mock is *theme-aware*:
  the card is drawn by the chosen theme's
  `onboarding_preview/1` (Quill's glassmorphism step band and month grid,
  Rhythm's compact week strip and slot list), around the identity header
  this module owns, so the picker feels like a real choice rather than a
  label swap.

  Per-user colours come from the theme's resolved customisation tokens and
  are applied via inline `style`; structural layout is Tailwind utilities.
  The component is pure: its only lookup is that resolution, which reads no
  database.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]
  import TymeslotWeb.OnboardingLive.PreviewParts, only: [color: 3, divider_style: 1, ring: 2]

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.OnboardingLive.TextHelpers
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @default_theme_id Catalog.default_id()

  @doc """
  Renders the live booking-page preview.

  See the `attr` declarations below. All values are resolved from the parent
  LiveView's assigns and reflect the in-progress onboarding state.
  """
  attr :current_step, :atom, required: true
  attr :booking_theme, :string, default: @default_theme_id
  attr :name, :string, default: ""
  attr :username, :string, default: ""
  attr :avatar_url, :string, default: nil

  attr :theme_customization, :any,
    default: nil,
    doc: "the chosen theme's customisation; `nil` draws the theme's defaults"

  attr :buffer_before_minutes, :integer, default: nil
  attr :buffer_after_minutes, :integer, default: nil
  attr :advance_booking_days, :integer, default: nil
  attr :min_advance_hours, :integer, default: nil
  attr :calendar_connected, :boolean, default: false
  attr :booking_host, :string, required: true

  @spec live_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def live_preview(assigns) do
    assigns =
      assigns
      |> assign(:colors, preview_colors(assigns.booking_theme, assigns.theme_customization))
      |> assign(:theme_module, theme_module(assigns.booking_theme))
      |> assign(:display_name, display_name(assigns.name))
      |> assign(:link_text, link_text(assigns.booking_host, assigns.username))
      |> assign(:caption, caption(assigns))
      |> assign(:slots, build_slots(assigns))
      |> assign(:locale, Gettext.get_locale(TymeslotWeb.Gettext))

    ~H"""
    <div class="w-full max-w-sm mx-auto">
      <div class="rounded-token-3xl p-6 shadow-glass-lg" style={backdrop_style(@colors)}>
        <PreviewParts.theme_preview
          theme_module={@theme_module}
          variant={:card}
          colors={@colors}
          slots={@slots}
          locale={@locale}
          highlight_card={highlight?(@current_step, :card)}
          highlight_slots={highlight?(@current_step, :slots)}
        >
          <:header>
            <%!-- Avatar + identity --%>
            <div
              class="w-16 h-16 rounded-full overflow-hidden bg-white/10"
              style={avatar_style(@colors, highlight?(@current_step, :avatar))}
            >
              <img src={@avatar_url} alt="" class="w-full h-full object-cover" />
            </div>
            <p class="font-bold text-token-base text-center" style={text_style(@colors)}>
              {@display_name}
            </p>
            <span
              class="text-token-xs px-3 py-1 rounded-token-full font-medium"
              style={link_style(@colors, highlight?(@current_step, :link))}
            >
              {@link_text}
            </span>

            <div class="w-full h-px my-1" style={divider_style(@colors)} />

            <%!-- Buffer callout: a labelled gap around meetings, never a slot --%>
            <.buffer_callout
              :if={@current_step == :buffer_time}
              colors={@colors}
              before_minutes={@buffer_before_minutes || 15}
              after_minutes={@buffer_after_minutes || 15}
            />
          </:header>
        </PreviewParts.theme_preview>

        <p class="mt-4 text-center text-token-xs font-medium" style={caption_style(@colors)}>
          {@caption}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Neutral loading placeholder for the disconnected (dead) render.

  On the dead render there is no profile yet, so the real preview would paint
  with default colours and then flash to the user's actual theme the instant
  the socket connects. A neutral skeleton reads as "loading" instead, so the
  preview resolves straight to the right colours with no visible colour swap.
  """
  @spec preview_skeleton(map()) :: Phoenix.LiveView.Rendered.t()
  def preview_skeleton(assigns) do
    ~H"""
    <div class="w-full max-w-sm mx-auto">
      <div class="rounded-token-3xl p-6 shadow-glass-lg bg-tymeslot-900/80">
        <div class="rounded-token-3xl p-5 bg-white/95 flex flex-col items-center gap-3 animate-pulse">
          <div class="w-16 h-16 rounded-full bg-tymeslot-200" />
          <div class="h-3 w-1/2 rounded-full bg-tymeslot-200" />
          <div class="h-2 w-2/3 rounded-full bg-tymeslot-100" />
          <div class="w-full h-px my-1 bg-tymeslot-100" />
          <div class="grid grid-cols-2 gap-1.5 w-full">
            <div :for={_n <- 1..4} class="h-7 rounded-token-md bg-tymeslot-100" />
          </div>
          <div class="w-full h-8 rounded-token-xl bg-tymeslot-200 mt-1" />
        </div>
        <div class="mt-4 h-2 w-1/2 mx-auto rounded-full bg-tymeslot-700/40" />
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Shared buffer piece
  # -------------------------------------------------------------------

  attr :colors, :map, required: true
  attr :before_minutes, :integer, required: true
  attr :after_minutes, :integer, required: true

  defp buffer_callout(assigns) do
    ~H"""
    <div
      class="w-full flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-token-md text-token-2xs font-bold uppercase tracking-wide"
      style={buffer_style(@colors)}
    >
      <.icon name="hero-arrows-up-down-mini" class="w-3 h-3" />
      {buffer_callout_text(@before_minutes, @after_minutes)}
    </div>
    """
  end

  defp buffer_callout_text(0, 0),
    do: dgettext("onboarding_wizard", "No buffer around meetings")

  defp buffer_callout_text(0, after_minutes),
    do:
      dgettext("onboarding_wizard", "No buffer before, %{after_minutes} min after",
        after_minutes: after_minutes
      )

  defp buffer_callout_text(before_minutes, 0),
    do:
      dgettext("onboarding_wizard", "%{before_minutes} min before, no buffer after",
        before_minutes: before_minutes
      )

  defp buffer_callout_text(before_minutes, after_minutes),
    do:
      dgettext("onboarding_wizard", "%{before_minutes} min before, %{after_minutes} min after",
        before_minutes: before_minutes,
        after_minutes: after_minutes
      )

  # -------------------------------------------------------------------
  # Theme + slot resolution
  # -------------------------------------------------------------------

  defp theme_module(id) do
    ThemeInfo.get_theme_module(id) || ThemeInfo.get_theme_module(Catalog.default_id())
  end

  defp build_slots(assigns) do
    ~w(9:00 9:30 10:00 10:30)
    |> Enum.with_index()
    |> Enum.map(fn {label, index} ->
      %{label: label, state: slot_state(assigns, index), check: check?(assigns, index)}
    end)
  end

  defp check?(%{current_step: :connect_calendar, calendar_connected: true}, 0), do: true
  defp check?(_assigns, _index), do: false

  defp slot_state(%{current_step: :connect_calendar, calendar_connected: false}, _index),
    do: :muted

  defp slot_state(%{current_step: :connect_calendar}, _index), do: :filled
  defp slot_state(%{current_step: :minimum_notice}, index) when index <= 1, do: :muted
  defp slot_state(_assigns, _index), do: :default

  # -------------------------------------------------------------------
  # Captions
  # -------------------------------------------------------------------

  defp caption(%{current_step: :welcome}),
    do: dgettext("onboarding_wizard", "This is your live booking page")

  defp caption(%{current_step: :profile}),
    do: dgettext("onboarding_wizard", "Your page, your brand")

  defp caption(%{current_step: :connect_calendar, calendar_connected: true}),
    do: dgettext("onboarding_wizard", "Your calendar is synced - these slots are live")

  defp caption(%{current_step: :connect_calendar}),
    do: dgettext("onboarding_wizard", "Connect your calendar to fill these slots")

  defp caption(%{current_step: :buffer_time}),
    do: dgettext("onboarding_wizard", "A breather around each meeting")

  defp caption(%{current_step: :booking_window} = assigns) do
    dgettext("onboarding_wizard", "Bookable up to %{days}",
      days: TextHelpers.humanize_days(assigns.advance_booking_days)
    )
  end

  defp caption(%{current_step: :minimum_notice} = assigns) do
    dgettext("onboarding_wizard", "Earliest booking: %{hours}h from now",
      hours: assigns.min_advance_hours || 0
    )
  end

  defp caption(%{current_step: :ready} = assigns) do
    dgettext("onboarding_wizard", "You're all set - %{link} is live",
      link: link_text(assigns.booking_host, assigns.username)
    )
  end

  defp caption(_assigns), do: dgettext("onboarding_wizard", "This is your live booking page")

  # -------------------------------------------------------------------
  # Highlight regions
  # -------------------------------------------------------------------

  defp highlight?(:welcome, :card), do: true
  defp highlight?(:ready, :card), do: true
  defp highlight?(:profile, :avatar), do: true
  defp highlight?(:profile, :link), do: true
  defp highlight?(:booking_window, :slots), do: true
  defp highlight?(_step, _region), do: false

  # -------------------------------------------------------------------
  # Value helpers
  # -------------------------------------------------------------------

  defp display_name(name) do
    case String.trim(name || "") do
      "" -> dgettext("onboarding_wizard", "Your name")
      trimmed -> trimmed
    end
  end

  defp link_text(host, username) do
    slug =
      case String.trim(username || "") do
        "" -> dgettext("onboarding_wizard", "your-link")
        trimmed -> trimmed
      end

    "#{host}/#{slug}"
  end

  # -------------------------------------------------------------------
  # Colour resolution
  # -------------------------------------------------------------------

  defp preview_colors(theme_id, customization) do
    theme_id |> ThemeCustomizations.tokens(customization) |> PreviewParts.colors()
  end

  # -------------------------------------------------------------------
  # Inline style builders (dynamic per-user data)
  # -------------------------------------------------------------------

  defp backdrop_style(colors) do
    "background: #{color(colors, :background, "#0f172a")};"
  end

  defp avatar_style(colors, highlighted?) do
    "border: 2px solid #{color(colors, :surface, "#ffffff")};" <> ring(highlighted?, colors)
  end

  defp text_style(colors), do: "color: #{color(colors, :text, "#0f172a")};"

  defp link_style(colors, highlighted?) do
    "background: #{color(colors, :primary, "#14b8a6")}1a;color: #{color(colors, :text_secondary, "#475569")};" <>
      ring(highlighted?, colors)
  end

  defp buffer_style(colors) do
    "background: #{color(colors, :accent, "#f59e0b")}26;color: #{color(colors, :text_secondary, "#475569")};"
  end

  defp caption_style(colors) do
    "color: #{color(colors, :text, "#e2e8f0")};"
  end
end
