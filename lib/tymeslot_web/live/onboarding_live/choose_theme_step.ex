defmodule TymeslotWeb.OnboardingLive.ChooseThemeStep do
  @moduledoc """
  Theme selection step for the onboarding flow.

  Lets the user pick a booking theme and accent colour scheme, and preview
  their *real* booking page full-screen. This step only appears once a
  calendar is connected — at that point the public page is ready, so the
  preview reflects the live page rather than a mock.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.ThemeCustomizations.Presets
  alias TymeslotWeb.Themes.Core.Registry

  # Stable display order for the colour-scheme swatches.
  @scheme_order ~w(default turquoise purple sunset ocean forest rose monochrome)

  @doc """
  Renders the theme + colour picker with a live full-page preview button.

  ## Attributes

  * `profile` - The user's profile struct (carries the selected `booking_theme`)
  * `theme_options` - List of `{name, id}` booking theme tuples
  * `color_scheme` - The currently selected colour-scheme id
  """
  attr :profile, :map, required: true
  attr :theme_options, :list, required: true
  attr :color_scheme, :string, required: true

  @spec choose_theme_step(map()) :: Phoenix.LiveView.Rendered.t()
  def choose_theme_step(assigns) do
    color_schemes = Presets.get_color_schemes()

    primary =
      color_schemes
      |> Map.get(assigns.color_scheme, %{})
      |> Map.get(:colors, %{})
      |> Map.get(:primary, "#14b8a6")

    assigns =
      assigns
      |> assign(:color_schemes, color_schemes)
      |> assign(:primary, primary)

    ~H"""
    <div class="onboarding-form">
      <%!-- Booking theme --%>
      <div class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Your booking theme")}</label>
        <p class="onboarding-form-helper">
          {dgettext("onboarding_wizard", "Pick the look and feel invitees see on your booking page.")}
        </p>
        <div class="grid grid-cols-2 gap-3">
          <button
            :for={{name, id} <- @theme_options}
            type="button"
            phx-click="select_theme"
            phx-value-theme={id}
            aria-pressed={to_string(theme_selected?(@profile, id))}
            class={[
              "p-3 rounded-token-xl border-2 flex flex-col gap-2 transition-colors",
              if(theme_selected?(@profile, id),
                do: "border-turquoise-500 bg-turquoise-50",
                else: "border-tymeslot-200 bg-white hover:border-tymeslot-300"
              )
            ]}
          >
            <.theme_thumbnail theme_key={resolve_theme_key(id)} primary={@primary} />
            <span class={[
              "font-semibold text-token-sm",
              if(theme_selected?(@profile, id), do: "text-turquoise-700", else: "text-tymeslot-600")
            ]}>
              {name}
            </span>
          </button>
        </div>
      </div>

      <%!-- Colour scheme --%>
      <div class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Colour scheme")}</label>
        <p class="onboarding-form-helper">
          {dgettext("onboarding_wizard", "Set the accent colour that ties your page together.")}
        </p>
        <div class="flex flex-wrap gap-3">
          <button
            :for={id <- scheme_ids(@color_schemes)}
            type="button"
            phx-click="select_color_scheme"
            phx-value-scheme={id}
            title={get_in(@color_schemes, [id, :name])}
            aria-label={get_in(@color_schemes, [id, :name])}
            class={[
              "w-9 h-9 rounded-full border-2 transition-transform hover:scale-110",
              if(@color_scheme == id,
                do: "border-turquoise-500 ring-2 ring-turquoise-200 scale-110",
                else: "border-white shadow-sm"
              )
            ]}
            style={"background: #{get_in(@color_schemes, [id, :colors, :primary]) || "#14b8a6"};"}
          />
        </div>
      </div>

      <%!-- Real full-page preview --%>
      <div class="onboarding-form-group">
        <button
          type="button"
          phx-click="preview_booking_page"
          class="btn-secondary px-5 py-2.5 inline-flex items-center gap-2 whitespace-nowrap"
        >
          <.icon name="hero-eye-mini" class="w-4 h-4 shrink-0" />
          {dgettext("onboarding_wizard", "Preview booking page")}
        </button>
        <p class="onboarding-form-helper mt-2">
          {dgettext(
            "onboarding_wizard",
            "Opens your real booking page exactly as invitees will see it."
          )}
        </p>
      </div>
    </div>
    """
  end

  # Miniature mock that resembles each theme at a glance: Quill shows its
  # signature numbered step band over a calendar grid; Rhythm shows its
  # compact vertical slot list. Tinted with the active scheme's primary.
  attr :theme_key, :atom, required: true
  attr :primary, :string, required: true

  defp theme_thumbnail(%{theme_key: :rhythm} = assigns) do
    ~H"""
    <div class="aspect-[4/3] w-full rounded-token-lg bg-tymeslot-900 p-2 flex flex-col gap-1.5 overflow-hidden">
      <div class="h-1.5 w-2/3 rounded-full bg-white/30" />
      <div :for={_row <- 1..3} class="h-2.5 rounded-token-sm bg-white/10 flex items-center px-1">
        <span class="h-1 w-1/3 rounded-full" style={"background: #{@primary};"} />
      </div>
    </div>
    """
  end

  defp theme_thumbnail(assigns) do
    ~H"""
    <div class="aspect-[4/3] w-full rounded-token-lg bg-tymeslot-900 p-2 flex flex-col gap-1.5 overflow-hidden">
      <div class="flex items-center justify-center gap-1">
        <span
          :for={n <- 1..4}
          class="w-2 h-2 rounded-full"
          style={
            if(n == 1, do: "background: #{@primary};", else: "background: rgba(255,255,255,0.25);")
          }
        />
      </div>
      <div class="grid grid-cols-5 gap-0.5">
        <span
          :for={cell <- 0..9}
          class="aspect-square rounded-token-sm"
          style={
            if(cell in [2, 6],
              do: "background: #{@primary};",
              else: "background: rgba(255,255,255,0.12);"
            )
          }
        />
      </div>
    </div>
    """
  end

  defp theme_selected?(profile, id), do: (profile && profile.booking_theme) == id

  defp resolve_theme_key(id) do
    case Registry.id_to_key(id) do
      {:ok, key} -> key
      {:error, :invalid_theme_id} -> Registry.default_theme_key()
    end
  end

  # Returns colour-scheme ids in a stable display order, appending any
  # ids not present in the canonical list defensively.
  defp scheme_ids(color_schemes) do
    known = Enum.filter(@scheme_order, &Map.has_key?(color_schemes, &1))
    extra = Map.keys(color_schemes) -- known
    known ++ extra
  end
end
