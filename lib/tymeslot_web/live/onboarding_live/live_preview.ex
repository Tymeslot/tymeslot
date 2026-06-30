defmodule TymeslotWeb.OnboardingLive.LivePreview do
  @moduledoc """
  Live preview panel for the onboarding flow.

  Renders a miniature mock of the user's public booking page that updates
  reactively as the onboarding form is filled in. The mock is *theme-aware*:
  it reshapes itself to resemble the chosen scheduling theme so the picker
  feels like a real choice rather than a label swap.

    * **Quill** — glassmorphism. Generous corners, the signature numbered
      step band, a full month calendar grid and a multi-column slot grid.
    * **Rhythm** — compact and motion-driven. Tighter corners, a single
      week strip and a vertical, scrollable list of time slots.

  Per-user colours come from the static colour-scheme preset table and are
  applied via inline `style`; structural layout is Tailwind utilities. The
  component is pure — its only external lookup is that preset table.
  """

  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.ThemeCustomizations.Presets

  @default_scheme "default"

  @doc """
  Renders the live booking-page preview.

  See the `attr` declarations below. All values are resolved from the parent
  LiveView's assigns and reflect the in-progress onboarding state.
  """
  attr :current_step, :atom, required: true
  attr :booking_theme, :string, default: "1"
  attr :name, :string, default: ""
  attr :username, :string, default: ""
  attr :timezone, :string, default: nil
  attr :avatar_url, :string, default: nil
  attr :color_scheme, :string, default: @default_scheme
  attr :buffer_minutes, :integer, default: nil
  attr :advance_booking_days, :integer, default: nil
  attr :min_advance_hours, :integer, default: nil
  attr :calendar_connected, :boolean, default: false
  attr :booking_host, :string, required: true

  @spec live_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def live_preview(assigns) do
    assigns =
      assigns
      |> assign(:colors, scheme_colors(assigns.color_scheme))
      |> assign(:theme, theme_key(assigns.booking_theme))
      |> assign(:display_name, display_name(assigns.name))
      |> assign(:link_text, link_text(assigns.booking_host, assigns.username))
      |> assign(:caption, caption(assigns))
      |> assign(:slots, build_slots(assigns))

    ~H"""
    <div class="w-full max-w-sm mx-auto">
      <div class="rounded-token-3xl p-6 shadow-glass-lg" style={backdrop_style(@colors)}>
        <div class={card_class(@theme)} style={card_style(@colors, highlight?(@current_step, :card))}>
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

          <%!-- Buffer callout — a labelled gap between meetings, never a slot --%>
          <.buffer_callout
            :if={@current_step == :buffer_time}
            colors={@colors}
            minutes={@buffer_minutes || 15}
          />

          <%!-- Theme-specific body --%>
          <.quill_body :if={@theme == :quill} colors={@colors} slots={@slots} step={@current_step} />
          <.rhythm_body :if={@theme == :rhythm} colors={@colors} slots={@slots} step={@current_step} />

          <button
            type="button"
            class={book_class(@theme)}
            style={book_style(@colors, @theme)}
            disabled
          >
            Book
          </button>
        </div>

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
  # Theme bodies
  # -------------------------------------------------------------------

  # Quill: numbered step band + month calendar grid + multi-column slot grid.
  attr :colors, :map, required: true
  attr :slots, :list, required: true
  attr :step, :atom, required: true

  defp quill_body(assigns) do
    ~H"""
    <div class="w-full flex flex-col gap-3">
      <%!-- Signature numbered step band --%>
      <div class="flex items-center justify-center gap-1.5">
        <%= for n <- 1..4 do %>
          <span
            class="w-5 h-5 rounded-full text-token-2xs font-bold inline-flex items-center justify-center"
            style={step_dot_style(@colors, n == 1)}
          >
            {n}
          </span>
          <span :if={n < 4} class="w-3 h-px" style={divider_style(@colors)} />
        <% end %>
      </div>

      <%!-- Mini month calendar (7 columns) --%>
      <div class="grid grid-cols-7 gap-1" style={slots_style(highlight?(@step, :slots))}>
        <%= for day <- 0..20 do %>
          <span class="aspect-square rounded-token-sm" style={calendar_cell_style(@colors, day)} />
        <% end %>
      </div>

      <%!-- Multi-column slot grid --%>
      <div class="grid grid-cols-2 gap-1.5" style={slots_style(highlight?(@step, :slots))}>
        <.slot_chip :for={slot <- @slots} colors={@colors} slot={slot} />
      </div>
    </div>
    """
  end

  # Rhythm: compact week strip + vertical, scrollable slot list.
  defp rhythm_body(assigns) do
    ~H"""
    <div class="w-full flex flex-col gap-2">
      <%!-- Single week strip --%>
      <div class="flex justify-between gap-1">
        <%= for day <- 0..6 do %>
          <span
            class="grow h-6 rounded-token-md inline-flex items-center justify-center text-token-2xs font-semibold"
            style={week_cell_style(@colors, day == 2)}
          >
            {Enum.at(~w(M T W T F S S), day)}
          </span>
        <% end %>
      </div>

      <%!-- Vertical slot list --%>
      <div class="flex flex-col gap-1.5" style={slots_style(highlight?(@step, :slots))}>
        <.slot_row :for={slot <- @slots} colors={@colors} slot={slot} />
      </div>
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Shared slot + buffer pieces
  # -------------------------------------------------------------------

  attr :colors, :map, required: true
  attr :slot, :map, required: true

  defp slot_chip(assigns) do
    ~H"""
    <span
      class="text-token-xs px-2 py-1.5 rounded-token-md font-medium inline-flex items-center justify-center gap-1"
      style={slot_style(@colors, @slot.state)}
    >
      <.icon :if={@slot.check} name="hero-check-mini" class="w-3 h-3" />
      {@slot.label}
    </span>
    """
  end

  defp slot_row(assigns) do
    ~H"""
    <span
      class="text-token-xs px-3 py-2 rounded-token-md font-medium w-full inline-flex items-center gap-1.5"
      style={slot_style(@colors, @slot.state)}
    >
      <.icon :if={@slot.check} name="hero-check-mini" class="w-3 h-3" />
      {@slot.label}
    </span>
    """
  end

  attr :colors, :map, required: true
  attr :minutes, :integer, required: true

  defp buffer_callout(assigns) do
    ~H"""
    <div
      class="w-full flex items-center justify-center gap-1.5 px-3 py-1.5 rounded-token-md text-token-2xs font-bold uppercase tracking-wide"
      style={buffer_style(@colors)}
    >
      <.icon name="hero-arrows-up-down-mini" class="w-3 h-3" />
      {@minutes} min buffer between meetings
    </div>
    """
  end

  # -------------------------------------------------------------------
  # Theme + slot resolution
  # -------------------------------------------------------------------

  defp theme_key("2"), do: :rhythm
  defp theme_key(2), do: :rhythm
  defp theme_key(_id), do: :quill

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

  defp caption(%{current_step: :welcome}), do: "This is your live booking page"
  defp caption(%{current_step: :profile}), do: "Your page, your brand"

  defp caption(%{current_step: :connect_calendar, calendar_connected: true}),
    do: "Your calendar is synced — these slots are live"

  defp caption(%{current_step: :connect_calendar}),
    do: "Connect your calendar to fill these slots"

  defp caption(%{current_step: :buffer_time} = assigns),
    do: "A breather between meetings (#{assigns.buffer_minutes || 15} min)"

  defp caption(%{current_step: :booking_window} = assigns),
    do: "Bookable up to #{humanize_days(assigns.advance_booking_days)}"

  defp caption(%{current_step: :minimum_notice} = assigns),
    do: "Earliest booking: #{assigns.min_advance_hours || 0}h from now"

  defp caption(%{current_step: :ready} = assigns),
    do: "You're all set — #{link_text(assigns.booking_host, assigns.username)} is live"

  defp caption(_assigns), do: "This is your live booking page"

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
      "" -> "Your name"
      trimmed -> trimmed
    end
  end

  defp link_text(host, username) do
    slug =
      case String.trim(username || "") do
        "" -> "your-link"
        trimmed -> trimmed
      end

    "#{host}/#{slug}"
  end

  defp humanize_days(nil), do: "90 days"
  defp humanize_days(7), do: "1 week"
  defp humanize_days(14), do: "2 weeks"
  defp humanize_days(30), do: "1 month"
  defp humanize_days(90), do: "3 months"
  defp humanize_days(180), do: "6 months"
  defp humanize_days(365), do: "1 year"
  defp humanize_days(days), do: "#{days} days"

  # -------------------------------------------------------------------
  # Colour resolution
  # -------------------------------------------------------------------

  defp scheme_colors(id) do
    schemes = Presets.get_color_schemes()
    scheme = Map.get(schemes, id) || Map.get(schemes, @default_scheme) || %{}
    Map.get(scheme, :colors, %{})
  end

  defp color(colors, key, fallback), do: Map.get(colors, key) || fallback

  # -------------------------------------------------------------------
  # Theme-shaped class helpers
  # -------------------------------------------------------------------

  defp card_class(:rhythm), do: "rounded-token-2xl p-5 flex flex-col items-center gap-3"
  defp card_class(_quill), do: "rounded-token-3xl p-5 flex flex-col items-center gap-3"

  defp book_class(:rhythm),
    do: "w-full py-2 rounded-token-lg font-semibold text-white text-token-sm mt-1"

  defp book_class(_quill),
    do: "w-full py-2 rounded-token-xl font-semibold text-white text-token-sm mt-1"

  # -------------------------------------------------------------------
  # Inline style builders (dynamic per-user data)
  # -------------------------------------------------------------------

  defp backdrop_style(colors) do
    "background: #{color(colors, :background, "#0f172a")};"
  end

  defp card_style(colors, highlighted?) do
    "background: #{color(colors, :surface, "#ffffff")};color: #{color(colors, :text, "#0f172a")};" <>
      ring(highlighted?, colors)
  end

  defp avatar_style(colors, highlighted?) do
    "border: 2px solid #{color(colors, :surface, "#ffffff")};" <> ring(highlighted?, colors)
  end

  defp text_style(colors), do: "color: #{color(colors, :text, "#0f172a")};"

  defp link_style(colors, highlighted?) do
    "background: #{color(colors, :primary, "#14b8a6")}1a;color: #{color(colors, :text_secondary, "#475569")};" <>
      ring(highlighted?, colors)
  end

  defp divider_style(colors) do
    "background: #{color(colors, :text_secondary, "#475569")}26;"
  end

  defp step_dot_style(colors, true) do
    "background: #{color(colors, :primary, "#14b8a6")};color: #ffffff;"
  end

  defp step_dot_style(colors, false) do
    "background: #{color(colors, :primary, "#14b8a6")}1f;color: #{color(colors, :text_secondary, "#475569")};"
  end

  # A few cells get the primary tint to read as "available days".
  defp calendar_cell_style(colors, day) when day in [4, 9, 12, 17] do
    "background: #{color(colors, :primary, "#14b8a6")};"
  end

  defp calendar_cell_style(colors, _day) do
    "background: #{color(colors, :primary, "#14b8a6")}14;"
  end

  defp week_cell_style(colors, true) do
    "background: #{color(colors, :primary, "#14b8a6")};color: #ffffff;"
  end

  defp week_cell_style(colors, false) do
    "background: #{color(colors, :primary, "#14b8a6")}14;color: #{color(colors, :text_secondary, "#475569")};"
  end

  defp slots_style(highlighted?) do
    if highlighted?, do: "opacity: 1;", else: ""
  end

  defp slot_style(colors, :muted) do
    "background: #{color(colors, :text_secondary, "#475569")}1f;color: #{color(colors, :text_secondary, "#475569")};opacity: 0.5;"
  end

  defp slot_style(colors, :filled) do
    "background: #{color(colors, :primary, "#14b8a6")}26;color: #{color(colors, :primary, "#14b8a6")};"
  end

  defp slot_style(colors, _state) do
    "background: #{color(colors, :primary, "#14b8a6")}14;color: #{color(colors, :text, "#0f172a")};"
  end

  defp buffer_style(colors) do
    "background: #{color(colors, :accent, "#f59e0b")}26;color: #{color(colors, :text_secondary, "#475569")};"
  end

  defp book_style(colors, :quill) do
    "background: linear-gradient(135deg, #{color(colors, :primary, "#14b8a6")}, #{color(colors, :accent, "#f59e0b")});"
  end

  defp book_style(colors, _rhythm) do
    "background: #{color(colors, :primary, "#14b8a6")};"
  end

  defp caption_style(colors) do
    "color: #{color(colors, :text, "#e2e8f0")};"
  end

  defp ring(false, _colors), do: ""

  defp ring(true, colors) do
    "box-shadow: 0 0 0 3px #{color(colors, :primary, "#14b8a6")};"
  end
end
