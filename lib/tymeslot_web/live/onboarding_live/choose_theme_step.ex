defmodule TymeslotWeb.OnboardingLive.ChooseThemeStep do
  @moduledoc """
  Theme selection step for the onboarding flow.

  Shows a thumbnail of every offered theme's look, each a button sending
  `select_theme`. The stage shows one theme at a time, so the thumbnails are
  the only place a host sees them all at once. Below them sits whatever the
  chosen theme's customisation spec offers for onboarding (a colour
  scheme, for a theme with a palette), and, for a theme that introduces the
  host (`Catalog.shows_intro?/1`), one optional line about them, the headline
  its page shows under their name. It saves as it is typed
  (`ThemeHandlers.handle_headline_change/2`) and never holds up Continue; the
  bio is left to the dashboard.

  There is no separate preview: the stage beside the step (above it on a
  phone) redraws the host's page in the chosen theme and colours as they
  pick, and the last step shows the real page.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [input: 1]

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Renders the theme picker (every theme's look) and the spec's onboarding
  choices.

  ## Attributes

  * `profile` - The user's profile struct (carries the selected `booking_theme`)
  * `theme_options` - List of `{name, id}` booking theme tuples
  * `theme_customization` - The selected theme's customisation, or `nil`
  * `choices` - The theme's `ThemeCustomizations.onboarding_choices/1`; `nil`
    hides the choice row. Their names are translated through
    `dashboard_appearance`, as the dashboard's panels translate them.
  * `headline_form` - The headline form (`ThemeHandlers.headline_form/1`),
    shown only for a theme that introduces the host
  """
  attr :profile, :map, required: true
  attr :theme_options, :list, required: true
  attr :theme_customization, :any, required: true
  attr :choices, :map, default: nil
  attr :headline_form, Phoenix.HTML.Form, required: true

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
      |> assign(:shows_intro, Catalog.shows_intro?(theme_id))

    ~H"""
    <div class="onboarding-form">
      <%!-- Booking theme, by look: every theme's thumbnail --%>
      <div class="onboarding-form-group">
        <%!-- The step's description already asks for a look, so the group
             needs only its name. From lg the thumbnails share one row. --%>
        <span id="theme-look-question" class="label">
          {dgettext("onboarding_wizard", "Your booking theme")}
        </span>
        <div
          role="group"
          aria-labelledby="theme-look-question"
          class="grid grid-cols-2 lg:grid-cols-4 gap-3 lg:gap-2"
        >
          <button
            :for={{name, id} <- @theme_options}
            type="button"
            phx-click="select_theme"
            phx-value-theme={id}
            data-testid="theme-thumbnail"
            aria-pressed={to_string(theme_selected?(@profile, id))}
            class={[
              "p-3 lg:p-2 rounded-token-xl border-2 flex flex-col gap-2 lg:gap-1.5 transition-colors",
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
              "font-semibold text-token-sm lg:text-token-xs truncate",
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
        <%!-- 40px to tap; on a narrow phone the row wraps. --%>
        <div class="flex flex-wrap gap-2 lg:gap-3">
          <button
            :for={choice <- @choices.choices}
            type="button"
            phx-click="select_onboarding_choice"
            phx-value-choice={choice.value}
            title={choice_name(choice.name)}
            aria-label={choice_name(choice.name)}
            class={[
              "w-10 h-10 rounded-full border-2 transition-transform hover:scale-110",
              if(@selected == choice.value,
                do: "border-turquoise-500 ring-2 ring-turquoise-200 scale-110",
                else: "border-white shadow-sm"
              )
            ]}
            style={"background: #{choice.swatch};"}
          />
        </div>
      </div>

      <%!-- A theme that introduces the host shows a line about them under
           their name; the stage shows it as it is typed. --%>
      <.form
        :if={@shows_intro}
        for={@headline_form}
        id="onboarding-headline-form"
        phx-change="headline_change"
        phx-submit="headline_change"
        class="onboarding-form-group"
      >
        <label class="label" for="onboarding-headline">
          {dgettext("onboarding_wizard", "One line about you (optional)")}
        </label>
        <p id="onboarding-headline-help" class="onboarding-form-helper">
          {dgettext(
            "onboarding_wizard",
            "Guests see it under your name. You can add a longer bio later in your dashboard."
          )}
        </p>
        <.input
          field={@headline_form[:headline]}
          id="onboarding-headline"
          type="text"
          placeholder={
            dgettext("onboarding_wizard", "For example: Career coach for first-time managers")
          }
          maxlength={Constraints.profile_headline_max_length()}
          autocomplete="off"
          aria-describedby="onboarding-headline-help"
          phx-debounce="300"
        />
      </.form>
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
