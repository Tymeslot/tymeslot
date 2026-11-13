defmodule TymeslotWeb.Dashboard.Languages.SettingsTab do
  @moduledoc """
  The Settings tab of the Languages page: one card listing every supported
  language, under a switch that offers them all.

  The switch is on by default: every language is ticked and the ticks are
  greyed out. Turned off, the organiser ticks the languages invitees can
  choose; each ticked language is also one they translate their texts into.
  Either way, any language can be made the original, the one the texts are
  written in, which is always offered.

  A language the organiser translates into shows how far it has got, and
  every language it can be translated into links to it on the Translations
  tab. Its events go to the owning `LanguagesComponent` (`myself`).
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.FlagHelpers, only: [locale_flag: 1]

  alias Tymeslot.Locales

  attr :original, :string, required: true
  attr :locales, :list, required: true, doc: "the translation languages"
  attr :offer_all, :boolean, required: true
  attr :progress, :map, required: true
  attr :myself, :any, required: true

  @spec settings_tab(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tab(assigns) do
    assigns = assign(assigns, :languages, Locales.supported())

    ~H"""
    <.card
      title={dgettext("dashboard_languages", "Booking page languages")}
      description={
        dgettext(
          "dashboard_languages",
          "The languages invitees can choose on your booking page. Your original is the one you write your texts in; in the others, invitees see your translations where you have made them."
        )
      }
      icon="hero-globe-alt"
    >
      <div class="space-y-4">
        <.setting_row
          id="offer-all-locales"
          control={:switch}
          label={dgettext("dashboard_languages", "Offer every language")}
          description={
            if @offer_all,
              do:
                dgettext(
                  "dashboard_languages",
                  "Invitees can choose any language Tymeslot supports. Turn this off to choose the languages yourself."
                ),
              else:
                dgettext(
                  "dashboard_languages",
                  "Invitees can choose only the languages ticked below."
                )
          }
          checked={@offer_all}
          on_change="toggle_offer_all"
          target={@myself}
        />

        <ul
          class={[
            "divide-y rounded-token-xl px-4 transition-colors",
            if(@offer_all,
              do: "bg-tymeslot-100/70 divide-tymeslot-200/70",
              else: "bg-transparent divide-tymeslot-100"
            )
          ]}
          data-testid="booking-languages"
        >
          <li
            :for={%{code: code, name: name} <- @languages}
            class="flex flex-wrap items-center justify-between gap-3 py-3 min-h-16"
            data-locale={code}
            data-ticked={to_string(@offer_all or code == @original or code in @locales)}
          >
            <label
              for={"language-#{code}"}
              class={[
                "flex items-center gap-3 min-w-0",
                if(@offer_all or code == @original,
                  do: "cursor-not-allowed",
                  else: "cursor-pointer"
                )
              ]}
            >
              <%!-- raw-input: each checkbox adds or removes its language the moment it is clicked, beside a flag and a progress line no core field wrapper lays out --%>
              <input
                type="checkbox"
                id={"language-#{code}"}
                class={["checkbox shrink-0", @offer_all && "opacity-40"]}
                checked={@offer_all or code == @original or code in @locales}
                disabled={@offer_all or code == @original}
                phx-click="toggle_locale"
                phx-value-locale={code}
                phx-target={@myself}
              />
              <.locale_flag
                locale={code}
                class={
                  if @offer_all and code != @original,
                    do: "w-6 h-4 shrink-0 opacity-60",
                    else: "w-6 h-4 shrink-0"
                }
              />
              <span class={[
                "font-bold",
                if(@offer_all and code != @original,
                  do: "text-tymeslot-500",
                  else: "text-tymeslot-800"
                )
              ]}>
                {name}
              </span>
              <.pill :if={code == @original} tone={:brand}>
                {dgettext("dashboard_languages", "Original")}
              </.pill>
            </label>
            <div :if={code != @original} class="flex flex-wrap items-center gap-3">
              <.progress_summary :if={code in @locales} progress={@progress[code]} />
              <.action_link
                class={if not (@offer_all or code in @locales), do: "invisible", else: ""}
                aria-hidden={if not (@offer_all or code in @locales), do: "true"}
                tabindex={if not (@offer_all or code in @locales), do: "-1"}
                patch={~p"/dashboard/languages/#{code}"}
                variant={:secondary}
                size={:sm}
                icon="hero-pencil-square"
                aria-label={
                  dgettext("dashboard_languages", "Translate into %{language}", language: name)
                }
                data-testid={"translate-#{code}"}
              >
                {dgettext("dashboard_languages", "Translate")}
              </.action_link>
              <.action_button
                variant={:ghost}
                size={:sm}
                phx-click="set_original"
                phx-value-locale={code}
                phx-target={@myself}
                aria-label={
                  dgettext("dashboard_languages", "Write my texts in %{language}", language: name)
                }
                data-testid={"make-original-#{code}"}
              >
                {dgettext("dashboard_languages", "Make original")}
              </.action_button>
            </div>
          </li>
        </ul>
      </div>
    </.card>
    """
  end

  attr :progress, :map, default: nil

  @doc "How far a language's translation has got: `3/10 translated`, and any outdated."
  @spec progress_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def progress_summary(%{progress: nil} = assigns), do: ~H""

  def progress_summary(assigns) do
    ~H"""
    <span class="text-token-sm text-tymeslot-500" data-testid="translation-progress">
      {dgettext("dashboard_languages", "%{translated}/%{total} translated",
        translated: @progress.translated,
        total: @progress.total
      )}
    </span>
    <.pill :if={@progress.outdated > 0} tone={:warning} dot>
      {dngettext(
        "dashboard_languages",
        "%{count} outdated",
        "%{count} outdated",
        @progress.outdated
      )}
    </.pill>
    """
  end
end
