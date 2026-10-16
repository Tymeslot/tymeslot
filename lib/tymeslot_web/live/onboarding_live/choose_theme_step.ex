defmodule TymeslotWeb.OnboardingLive.ChooseThemeStep do
  @moduledoc """
  Theme selection step for the onboarding flow.

  Asks the organiser which theme's story sounds like them: one button per
  offered theme, its first-person story (`story/0`, from the theme's persona
  sheet) above its name. "Show all themes" swaps the stories for the visual
  picker of every theme's look, and "Choose by description instead" swaps
  back; both send the same `select_theme` event. Below either sits whatever
  the chosen theme's customisation spec offers for onboarding (a colour
  scheme, for a theme with a palette), and a button opening the organiser's
  *real* booking page full-screen. This step only appears once a calendar is
  connected: at that point the public page is ready, so the preview reflects
  the live page rather than a mock.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [action_button: 1]

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Core.ThemeInfo

  @doc """
  Renders the theme picker (the stories, or every theme's look), the spec's
  onboarding choices and a live full-page preview button.

  ## Attributes

  * `profile` - The user's profile struct (carries the selected `booking_theme`)
  * `theme_options` - List of `{name, id}` booking theme tuples
  * `theme_customization` - The selected theme's customisation, or `nil`
  * `choices` - The theme's `ThemeCustomizations.onboarding_choices/1`; `nil`
    hides the choice row. Their names are translated through
    `dashboard_appearance`, as the dashboard's panels translate them.
  * `picker` - `:stories` (the default: "Which of these sounds like you?")
    or `:all` (every theme's thumbnail)
  """
  attr :profile, :map, required: true
  attr :theme_options, :list, required: true
  attr :theme_customization, :any, required: true
  attr :choices, :map, default: nil
  attr :picker, :atom, default: :stories, values: [:stories, :all]

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
      |> assign(:stories, stories(assigns.theme_options))

    ~H"""
    <div class="onboarding-form">
      <%!-- Booking theme, by story: the organiser picks a sentence they
           recognise, not a screenshot --%>
      <div :if={@picker == :stories} class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Your booking theme")}</label>
        <p id="theme-story-question" class="onboarding-form-helper">
          {dgettext("onboarding_wizard", "Which of these sounds like you?")}
        </p>
        <div role="group" aria-labelledby="theme-story-question" class="flex flex-col gap-3">
          <button
            :for={story <- @stories}
            type="button"
            phx-click="select_theme"
            phx-value-theme={story.id}
            aria-pressed={to_string(theme_selected?(@profile, story.id))}
            data-testid="theme-story"
            class={[
              "p-4 rounded-token-xl border-2 flex flex-col gap-2 text-left transition-colors",
              if(theme_selected?(@profile, story.id),
                do: "border-turquoise-500 bg-turquoise-50",
                else: "border-tymeslot-200 bg-white hover:border-tymeslot-300"
              )
            ]}
          >
            <q class="text-token-base text-tymeslot-800 leading-relaxed">{story.story}</q>
            <span class={[
              "font-semibold text-token-sm",
              if(theme_selected?(@profile, story.id),
                do: "text-turquoise-700",
                else: "text-tymeslot-600"
              )
            ]}>
              {story.name}
            </span>
          </button>
        </div>
        <button
          type="button"
          phx-click="show_all_themes"
          class="mt-3 text-token-sm font-semibold text-turquoise-700 hover:text-turquoise-800 underline underline-offset-2"
        >
          {dgettext("onboarding_wizard", "Show all themes")}
        </button>
      </div>

      <%!-- Booking theme, by look: every theme's thumbnail --%>
      <div :if={@picker == :all} class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Your booking theme")}</label>
        <p id="theme-look-question" class="onboarding-form-helper">
          {dgettext("onboarding_wizard", "Pick the look and feel invitees see on your booking page.")}
        </p>
        <div role="group" aria-labelledby="theme-look-question" class="grid grid-cols-2 gap-3">
          <button
            :for={{name, id} <- @theme_options}
            type="button"
            phx-click="select_theme"
            phx-value-theme={id}
            data-testid="theme-thumbnail"
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
        <button
          type="button"
          phx-click="show_theme_stories"
          class="mt-3 text-token-sm font-semibold text-turquoise-700 hover:text-turquoise-800 underline underline-offset-2"
        >
          {dgettext("onboarding_wizard", "Choose by description instead")}
        </button>
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
        <.action_button
          variant={:secondary}
          icon="hero-eye-mini"
          phx-click="preview_booking_page"
        >
          {dgettext("onboarding_wizard", "Preview booking page")}
        </.action_button>
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

  # Each offered theme's first-person story, in the pickers' order. `story/0`
  # is translated into the current locale, as `metadata/0`'s description is.
  # The `<q>` around it lets the browser draw the locale's own quotation
  # marks.
  defp stories(theme_options) do
    for {name, id} <- theme_options, do: %{id: id, name: name, story: theme_module(id).story()}
  end

  # The names come from the preset catalogues, which register the translatable
  # ones in `dashboard_appearance` (`dgettext_noop/2`), as the dashboard's
  # panels read them; a name with no entry there, such as a brand, is returned
  # as it is.
  defp choice_name(name), do: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_appearance", name)

  defp theme_module(id) do
    ThemeInfo.get_theme_module(id) || ThemeInfo.get_theme_module(Catalog.default_id())
  end
end
