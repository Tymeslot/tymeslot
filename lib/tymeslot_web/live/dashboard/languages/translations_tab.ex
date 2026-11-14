defmodule TymeslotWeb.Dashboard.Languages.TranslationsTab do
  @moduledoc """
  The Translations tab of the Languages page: one flag tab per translation
  language, and under the chosen one every translatable record
  (`Tymeslot.ContentTranslations.Catalogue.items/1`) on a card of its own
  with a `TranslationEditor`, the one place translations are written. Each
  text shows the original beside the box its translation goes in.

  A form that edits an original links to a record's card here
  (`TranslationStatus`), with `?item=` naming it; that card is highlighted.

  Switching language is an event, not a link, so the owning
  `LanguagesComponent` can have every editor save what was typed first.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.FlagHelpers, only: [locale_flag: 1]

  alias Tymeslot.ContentTranslations.Catalogue
  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Dashboard.Languages.Labels
  alias TymeslotWeb.Dashboard.Languages.SettingsTab
  alias TymeslotWeb.Dashboard.Languages.TranslationEditor
  alias TymeslotWeb.Dashboard.Languages.TranslationStatus

  @strip "translation-language-tabs"

  attr :locale, :string, required: true, doc: "the language being translated into"
  attr :locales, :list, required: true, doc: "every language it can translate into"
  attr :chosen, :list, required: true, doc: "the organiser's own translation languages"
  attr :original, :string, required: true
  attr :progress, :map, required: true
  attr :sections, :list, required: true, doc: "`{group, entities}` with something to show"
  attr :loaded, :boolean, required: true, doc: "whether the records have been read yet"
  attr :only_open, :boolean, required: true
  attr :user_id, :integer, required: true
  attr :item, :string, default: nil, doc: "the card a form linked to, highlighted"
  attr :editor_id, :any, required: true, doc: "`(group, entity) -> id` of an editor"
  attr :notify, :any, required: true, doc: "passed on to each `TranslationEditor`"
  attr :myself, :any, required: true

  @spec translations_tab(map()) :: Phoenix.LiveView.Rendered.t()
  def translations_tab(assigns) do
    assigns =
      assign(assigns,
        strip: @strip,
        tabs:
          Enum.map(
            assigns.locales,
            &language_tab(&1, &1 in assigns.chosen && assigns.progress[&1])
          ),
        language: Labels.language_name(assigns.locale),
        original_language: Labels.language_name(assigns.original)
      )

    ~H"""
    <.tab_bar
      id={@strip}
      active_tab={@locale}
      tabs={@tabs}
      event="switch_language"
      target={@myself}
      size={:sm}
      aria_label={dgettext("dashboard_languages", "Language to translate into")}
    />

    <div
      role="tabpanel"
      id={Navigation.panel_id(@strip, @locale)}
      aria-labelledby={Navigation.tab_id(@strip, @locale)}
      class="space-y-6"
    >
      <div class="space-y-2">
        <div class="flex flex-wrap items-center gap-3">
          <.locale_flag locale={@locale} class="w-8 h-6" />
          <.subsection_header
            level={2}
            size={:lg}
            title={dgettext("dashboard_languages", "Translate into %{language}", language: @language)}
          />
          <SettingsTab.progress_summary progress={@progress[@locale]} />
        </div>
        <p class="text-tymeslot-600 max-w-3xl" data-testid="translate-instruction">
          {dgettext(
            "dashboard_languages",
            "Each text you wrote in %{original} comes with a box for its %{language} version. Type the translation, then save the card. Until you do, invitees who choose %{language} see the %{original} text.",
            original: @original_language,
            language: @language
          )}
        </p>
      </div>

      <.setting_row
        id="only-open-translations"
        control={:switch}
        label={dgettext("dashboard_languages", "Only missing or outdated")}
        description={dgettext("dashboard_languages", "Hide the texts that are already translated.")}
        checked={@only_open}
        on_change="toggle_only_open"
        target={@myself}
      />

      <.empty_state
        :if={@loaded && @sections == []}
        icon="hero-check-circle"
        title={
          if @only_open,
            do: dgettext("dashboard_languages", "Everything is translated"),
            else: dgettext("dashboard_languages", "Nothing to translate yet")
        }
        description={
          if @only_open,
            do: dgettext("dashboard_languages", "No text is missing or outdated in this language."),
            else:
              dgettext(
                "dashboard_languages",
                "Write your booking page texts and meeting types first; they appear here to translate."
              )
        }
      />

      <section :for={{group, entities} <- @sections} class="space-y-4" data-group={group}>
        <.subsection_header level={2} title={group_title(group)} />
        <.card
          :for={entity <- entities}
          id={TranslationStatus.anchor(group, entity.kind, entity.id)}
          title={entity_title(group, entity)}
          class={[
            "scroll-mt-24",
            @item == TranslationStatus.anchor(group, entity.kind, entity.id) &&
              "ring-2 ring-turquoise-400"
          ]}
          data-highlighted={@item == TranslationStatus.anchor(group, entity.kind, entity.id)}
        >
          <.live_component
            module={TranslationEditor}
            id={@editor_id.(group, entity)}
            user_id={@user_id}
            kind={entity.kind}
            record={entity.record}
            locale={@locale}
            original={@original}
            paths={Enum.map(entity.fields, & &1.path)}
            only_open={@only_open}
            notify={@notify}
          />
        </.card>
      </section>
    </div>
    """
  end

  # A language's tab: its flag and name, with a dot while texts in it are
  # still missing or outdated.
  defp language_tab(locale, progress) do
    open = if progress, do: open_count(progress), else: 0
    tab = %{id: locale, label: Labels.language_name(locale), flag: locale}

    if open > 0,
      do:
        Map.merge(tab, %{
          status: :warning,
          status_label:
            dngettext(
              "dashboard_languages",
              "%{count} text to translate",
              "%{count} texts to translate",
              open
            )
        }),
      else: tab
  end

  @doc "How many texts are still missing or outdated in a language."
  @spec open_count(Catalogue.progress() | nil) :: non_neg_integer()
  def open_count(nil), do: 0

  def open_count(%{missing: missing, outdated: outdated})
      when is_integer(missing) and is_integer(outdated),
      do: missing + outdated

  defp group_title(:booking_texts), do: dgettext("dashboard_languages", "Booking page texts")
  defp group_title(:intro), do: dgettext("dashboard_languages", "About you")
  defp group_title(:meeting_types), do: dgettext("dashboard_languages", "Meeting types")
  defp group_title(:venues), do: dgettext("dashboard_languages", "Locations")

  defp entity_title(:booking_texts, %{kind: :profile}),
    do: dgettext("dashboard_languages", "Your booking page")

  defp entity_title(:intro, _entity), do: dgettext("dashboard_languages", "Headline and bio")
  defp entity_title(_group, %{name: name}), do: name
end
