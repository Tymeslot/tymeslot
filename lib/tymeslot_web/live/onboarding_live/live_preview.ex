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

  The card shows the host's real coming week (`PreviewWeek`): their dates
  before a calendar is connected, then their free times and busy blocks
  once the stage's week is ready, revealed once per new week.

  The miniature is drawn at 400px wide on the theme's canvas colour, and the
  onboarding stage scales it to fit (`StageFrame.scaled/1`); the stage takes
  the same canvas colour (`canvas/2`) around it.

  Per-user colours come from the theme's resolved customisation tokens and
  are applied via inline `style`; structural layout is Tailwind utilities.
  The component is pure: its only lookup is that resolution, which reads no
  database.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.OnboardingLive.PreviewParts, only: [color: 3, divider_style: 1, ring: 2]

  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.OnboardingLive.StageFrame
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

  attr :booking_host, :string, required: true

  attr :week, :map,
    default: nil,
    doc: "the stage's week, `%{state, preview}` (`PreviewWeek`); `nil` is the placeholder"

  attr :reveal_key, :integer,
    default: 0,
    doc: "bumped when a new week arrives, which reveals its times once"

  attr :today, Date,
    required: true,
    doc: "the host's date (`Tymeslot.Availability.today/1`), which dates the coming week"

  attr :id, :string,
    default: "stage",
    doc: "names this copy of the page, so the stage and its expanded copy never share an id"

  @spec live_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def live_preview(assigns) do
    assigns =
      assigns
      |> assign(:colors, preview_colors(assigns.booking_theme, assigns.theme_customization))
      |> assign(:theme_module, theme_module(assigns.booking_theme))
      |> assign(:display_name, display_name(assigns.name))
      |> assign(:link_host, assigns.booking_host <> "/")
      |> assign(:link_name, link_name(assigns.booking_host, assigns.username))
      |> assign(:locale, Gettext.get_locale(TymeslotWeb.Gettext))

    ~H"""
    <div class="w-[400px] p-6" style={backdrop_style(@colors)}>
      <PreviewParts.theme_preview
        theme_module={@theme_module}
        variant={:card}
        colors={@colors}
        week={@week}
        today={@today}
        locale={@locale}
        id={@id}
        reveal_key={@reveal_key}
        highlight={highlight(@current_step)}
      >
        <:header>
          <%!-- Avatar + identity --%>
          <div
            class="w-16 h-16 rounded-full overflow-hidden bg-white/10"
            style={avatar_style(@colors, highlight?(@current_step, :avatar))}
          >
            <img src={@avatar_url} alt="" class="w-full h-full object-cover" />
          </div>
          <p class="font-bold text-token-base text-center break-words" style={text_style(@colors)}>
            {@display_name}
          </p>
          <%!-- On a narrow card the host gives way, never the name. --%>
          <span
            class="max-w-full min-w-0 inline-flex text-token-xs px-3 py-1 rounded-token-full font-medium whitespace-nowrap"
            style={link_style(@colors, highlight?(@current_step, :link))}
            data-role="preview-address"
          >
            <span class="truncate">{@link_host}</span>
            <span class="shrink-0" data-role="preview-address-name">{@link_name}</span>
          </span>

          <div class="w-full h-px my-1" style={divider_style(@colors)} />
        </:header>
      </PreviewParts.theme_preview>
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
    <div class="w-[400px] p-6">
      <div class="rounded-token-3xl p-5 bg-white/95 flex flex-col items-center gap-3 motion-safe:animate-pulse">
        <div class="w-16 h-16 rounded-full bg-tymeslot-200" />
        <div class="h-3 w-1/2 rounded-full bg-tymeslot-200" />
        <div class="h-2 w-2/3 rounded-full bg-tymeslot-100" />
        <div class="w-full h-px my-1 bg-tymeslot-100" />
        <div class="grid grid-cols-2 gap-1.5 w-full">
          <div :for={_n <- 1..4} class="h-7 rounded-token-md bg-tymeslot-100" />
        </div>
        <div class="w-full h-8 rounded-token-xl bg-tymeslot-200 mt-1" />
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Theme + slot resolution
  # -------------------------------------------------------------------

  defp theme_module(id) do
    ThemeInfo.get_theme_module(id) || ThemeInfo.get_theme_module(Catalog.default_id())
  end

  # -------------------------------------------------------------------
  # Captions
  # -------------------------------------------------------------------

  @doc """
  The line the stage shows under the page, or `nil` for none. On the last
  step a live page gets its address; on the calendar and meeting steps a
  week that is ready gets what it shows (`week_caption/1`). Reads
  `current_step`, `booking_page_live`, `booking_host`, `username` and
  `stage_week`.
  """
  @spec caption(map()) :: String.t() | nil
  def caption(%{current_step: :ready, booking_page_live: true} = assigns) do
    dgettext("onboarding_wizard", "You're all set - %{link} is live",
      link: link_text(assigns.booking_host, assigns.username)
    )
  end

  def caption(%{current_step: step, stage_week: week}) when step in [:connect_calendar, :meeting],
    do: week_caption(week)

  def caption(_assigns), do: nil

  @doc """
  What a ready week shows, in a sentence: the first busy block, if any, and
  the number of open slots. `nil` for a week that is not ready. The stage
  shows it under the page and the live region announces it.
  """
  @spec week_caption(map() | nil) :: String.t() | nil
  def week_caption(%{state: :ready, preview: %WeekPreview{first_busy: nil} = preview}) do
    dngettext(
      "onboarding_wizard",
      "%{count} open slot this week.",
      "%{count} open slots this week.",
      preview.slot_count
    )
  end

  def week_caption(%{state: :ready, preview: %WeekPreview{first_busy: busy} = preview}) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    dngettext(
      "onboarding_wizard",
      "Your %{day} %{time} is already blocked. %{count} open slot this week.",
      "Your %{day} %{time} is already blocked. %{count} open slots this week.",
      preview.slot_count,
      day: LocaleFormat.format_weekday_name(Date.day_of_week(busy.date), locale, :full),
      time: LocaleFormat.format_time(busy.start, locale)
    )
  end

  def week_caption(_week), do: nil

  # -------------------------------------------------------------------
  # Highlight regions
  # -------------------------------------------------------------------

  # The regions of the theme's card ringed for a step (`PreviewParts.ring/2`),
  # which the stage also brings into view on a phone. Choosing a theme
  # changes the whole page, and the last step shows it finished, so neither
  # rings anything.
  defp highlight(:connect_calendar), do: [:calendar]
  defp highlight(:meeting), do: [:slots]
  defp highlight(_step), do: []

  # The header's own regions, which only the profile step rings.
  defp highlight?(:profile, :avatar), do: true
  defp highlight?(:profile, :link), do: true
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

  defp link_text(host, username), do: StageFrame.address(host, username)

  defp link_name(host, username),
    do: String.replace_prefix(link_text(host, username), host <> "/", "")

  # -------------------------------------------------------------------
  # Colour resolution
  # -------------------------------------------------------------------

  @doc """
  The theme's canvas colour: what the page is drawn on, and so what the
  stage around it takes.
  """
  @spec canvas(String.t(), term()) :: String.t()
  def canvas(theme_id, customization) do
    theme_id |> preview_colors(customization) |> canvas()
  end

  defp canvas(colors), do: color(colors, :background, "#0f172a")

  defp preview_colors(theme_id, customization) do
    theme_id |> ThemeCustomizations.tokens(customization) |> PreviewParts.colors()
  end

  # -------------------------------------------------------------------
  # Inline style builders (dynamic per-user data)
  # -------------------------------------------------------------------

  defp backdrop_style(colors) do
    "background: #{canvas(colors)};"
  end

  defp avatar_style(colors, highlighted?) do
    "border: 2px solid #{color(colors, :surface, "#ffffff")};" <> ring(highlighted?, colors)
  end

  defp text_style(colors), do: "color: #{color(colors, :text, "#0f172a")};"

  defp link_style(colors, highlighted?) do
    "background: #{color(colors, :primary, "#14b8a6")}1a;color: #{color(colors, :text_secondary, "#475569")};" <>
      ring(highlighted?, colors)
  end
end
