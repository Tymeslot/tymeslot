defmodule TymeslotWeb.OnboardingLive.ChooseThemeStep do
  @moduledoc """
  Theme selection step for the onboarding flow.

  Lets the user pick a booking theme and whatever its customisation spec
  offers for onboarding (a colour scheme, for a theme with a palette), and
  preview their *real* booking page full-screen. This step only appears once
  a calendar is connected: at that point the public page is ready, so the
  preview reflects the live page rather than a mock.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Renders the theme picker, the spec's onboarding choices and a live
  full-page preview button.

  ## Attributes

  * `profile` - The user's profile struct (carries the selected `booking_theme`)
  * `theme_options` - List of `{name, id}` booking theme tuples
  * `theme_customization` - The selected theme's customisation, or `nil`
  * `choices` - The theme's `ThemeCustomizations.onboarding_choices/1`; `nil`
    hides the choice row. Their names are translated through
    `dashboard_appearance`, as the dashboard's panels translate them.
  """
  attr :profile, :map, required: true
  attr :theme_options, :list, required: true
  attr :theme_customization, :any, required: true
  attr :choices, :map, default: nil

  @spec choose_theme_step(map()) :: Phoenix.LiveView.Rendered.t()
  def choose_theme_step(assigns) do
    theme_id = (assigns.profile && assigns.profile.booking_theme) || Catalog.default_id()

    colors =
      theme_id
      |> ThemeCustomizations.tokens(assigns.theme_customization)
      |> PreviewParts.colors()

    settings = ThemeCustomizations.to_map(assigns.theme_customization)

    assigns =
      assigns
      |> assign(:primary, PreviewParts.color(colors, :primary, "#14b8a6"))
      |> assign(:selected, assigns.choices && settings[assigns.choices.setting])

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
            <PreviewParts.theme_preview
              theme_module={theme_module(id)}
              variant={:thumbnail}
              primary={@primary}
            />
            <span class={[
              "font-semibold text-token-sm",
              if(theme_selected?(@profile, id), do: "text-turquoise-700", else: "text-tymeslot-600")
            ]}>
              {name}
            </span>
          </button>
        </div>
      </div>

      <%!-- The theme's onboarding choices (its colour schemes) --%>
      <div :if={@choices} class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Colour scheme")}</label>
        <p class="onboarding-form-helper">
          {dgettext("onboarding_wizard", "Set the accent colour that ties your page together.")}
        </p>
        <%!-- `choice`, not `value`: LiveView's client reads a button's native
        `value` property and would overwrite `phx-value-value` with "". --%>
        <div class="flex flex-wrap gap-3">
          <button
            :for={choice <- @choices.choices}
            type="button"
            phx-click="select_onboarding_choice"
            phx-value-choice={choice.value}
            title={choice_name(choice.name)}
            aria-label={choice_name(choice.name)}
            class={[
              "w-9 h-9 rounded-full border-2 transition-transform hover:scale-110",
              if(@selected == choice.value,
                do: "border-turquoise-500 ring-2 ring-turquoise-200 scale-110",
                else: "border-white shadow-sm"
              )
            ]}
            style={"background: #{choice.swatch};"}
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

  defp theme_selected?(profile, id), do: (profile && profile.booking_theme) == id

  # The names come from the preset catalogues, which register the translatable
  # ones in `dashboard_appearance` (`dgettext_noop/2`), as the dashboard's
  # panels read them; a name with no entry there, such as a brand, is returned
  # as it is.
  defp choice_name(name), do: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_appearance", name)

  defp theme_module(id) do
    ThemeInfo.get_theme_module(id) || ThemeInfo.get_theme_module(Catalog.default_id())
  end
end
