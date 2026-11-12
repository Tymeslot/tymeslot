defmodule TymeslotWeb.Dashboard.LanguagesComponent do
  @moduledoc """
  The Languages page: which languages the organiser's booking pages are
  offered in, and their texts' translations.

  At `/dashboard/languages` it holds the settings (`Tymeslot.Profiles.update_booking_languages/2`):
  the original language, the translation languages with how far each has got,
  and whether the booking page is offered in every language. At
  `/dashboard/languages/:language` it lists every translatable record
  (`Tymeslot.ContentTranslations.Catalogue.items/1`) with a
  `TranslationEditor` each, for reviewing that language in one place.

  Removing a translation language asks first (`RemoveLanguageModal`); its
  texts are kept, so adding the language again brings them back.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.FlagHelpers, only: [locale_flag: 1]

  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.Profiles
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Dashboard.Languages.Labels
  alias TymeslotWeb.Dashboard.Languages.RemoveLanguageModal
  alias TymeslotWeb.Dashboard.Languages.TranslationEditor

  @groups [:booking_texts, :intro, :meeting_types, :venues]

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       loaded_for: nil,
       removing_locale: nil,
       only_open: false,
       progress: %{},
       items: nil,
       review_locale: nil
     )}
  end

  # A saved translation changes only its own record, so it replaces that
  # record in the items already read and the progress is counted again from
  # them, without reading everything back.
  @impl Phoenix.LiveComponent
  def update(%{translation_saved: entity}, %{assigns: %{items: %{} = items}} = socket) do
    {:ok, socket |> assign(:items, replace_record(items, entity)) |> count_progress()}
  end

  def update(%{translation_saved: _entity}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    locales = Languages.translation_locales(socket.assigns.profile)
    # `:language`, not `:locale`: `LocalePlug` takes a `locale` param as the
    # visitor's choice of interface language, which would turn the dashboard
    # into the language under review.
    review_locale = (socket.assigns[:params] || %{})["language"]

    cond do
      is_binary(review_locale) and review_locale not in locales ->
        send(self(), {:patch, ~p"/dashboard/languages"})
        {:ok, socket}

      # The static render shows the page without its counts and texts, as
      # `DashboardLive` leaves its own data to the connected mount; reading
      # them here would read everything twice.
      not connected?(socket) ->
        {:ok, assign(socket, :review_locale, review_locale)}

      socket.assigns.loaded_for == {review_locale, locales} ->
        {:ok, socket}

      true ->
        {:ok,
         socket
         |> assign(review_locale: review_locale, loaded_for: {review_locale, locales})
         |> load()}
    end
  end

  # One read of everything translatable, from which every language's
  # progress is counted.
  defp load(socket) do
    socket
    |> assign(:items, Catalogue.items(socket.assigns.current_user.id))
    |> count_progress()
  end

  defp count_progress(%{assigns: %{items: items, review_locale: review_locale}} = socket) do
    locales =
      if review_locale,
        do: [review_locale],
        else: Languages.translation_locales(socket.assigns.profile)

    assign(socket, :progress, Catalogue.progress(items, locales))
  end

  # Each group keeps its own fields of the record (the profile appears in
  # two, with different texts), so only the record is replaced.
  defp replace_record(items, %{kind: kind, id: id, record: record}) do
    Map.new(items, fn {group, entities} ->
      {group,
       Enum.map(entities, fn
         %{kind: ^kind, id: ^id} = entity -> %{entity | record: record}
         entity -> entity
       end)}
    end)
  end

  @impl Phoenix.LiveComponent
  def handle_event("set_original", %{"content_locale" => code}, socket),
    do: {:noreply, save(socket, %{content_locale: code})}

  def handle_event("add_locale", %{"locale" => code}, socket) when code != "" do
    locales = Languages.translation_locales(socket.assigns.profile)
    {:noreply, save(socket, %{translation_locales: locales ++ [code]})}
  end

  def handle_event("add_locale", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_offer_all", _params, socket) do
    offer_all = not Languages.restricted?(socket.assigns.profile)
    {:noreply, save(socket, %{offer_all_locales: not offer_all})}
  end

  def handle_event("remove_locale", %{"locale" => code}, socket) do
    if code in Languages.translation_locales(socket.assigns.profile),
      do: {:noreply, assign(socket, :removing_locale, code)},
      else: {:noreply, socket}
  end

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :removing_locale, nil)}

  def handle_event("confirm_remove", _params, %{assigns: %{removing_locale: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_remove", _params, %{assigns: %{removing_locale: code}} = socket) do
    locales = Languages.translation_locales(socket.assigns.profile) -- [code]

    {:noreply,
     socket
     |> assign(:removing_locale, nil)
     |> save(%{translation_locales: locales})}
  end

  def handle_event("toggle_only_open", _params, socket),
    do: {:noreply, update(socket, :only_open, &(not &1))}

  defp save(socket, attrs) do
    case Profiles.update_booking_languages(socket.assigns.profile, attrs) do
      {:ok, profile} ->
        send(self(), {:profile_updated, profile})
        Flash.info(dgettext("dashboard_languages", "Languages saved"))
        socket |> assign(:profile, profile) |> reload()

      {:error, changeset} ->
        Flash.error(error_message(changeset))
        socket
    end
  end

  defp reload(socket) do
    locales = Languages.translation_locales(socket.assigns.profile)
    socket |> assign(:loaded_for, {socket.assigns.review_locale, locales}) |> load()
  end

  defp error_message(%{errors: [{_field, error} | _rest]}),
    do:
      dgettext("dashboard_languages", "Couldn't save your languages: %{reason}",
        reason: Forms.translate_error(error)
      )

  defp error_message(_changeset),
    do: dgettext("dashboard_languages", "Couldn't save your languages.")

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        original: Languages.original(assigns.profile),
        locales: Languages.translation_locales(assigns.profile),
        offer_all: not Languages.restricted?(assigns.profile)
      )

    ~H"""
    <div>
      <.dashboard_page icon="hero-language" title={dgettext("dashboard_languages", "Languages")}>
        <%= if @review_locale do %>
          <.review
            locale={@review_locale}
            progress={@progress[@review_locale]}
            items={@items}
            only_open={@only_open}
            user_id={@current_user.id}
            myself={@myself}
          />
        <% else %>
          <.settings
            original={@original}
            locales={@locales}
            offer_all={@offer_all}
            progress={@progress}
            myself={@myself}
          />
        <% end %>
      </.dashboard_page>

      <RemoveLanguageModal.remove_language_modal
        :if={@removing_locale}
        locale={@removing_locale}
        myself={@myself}
      />
    </div>
    """
  end

  attr :original, :string, required: true
  attr :locales, :list, required: true
  attr :offer_all, :boolean, required: true
  attr :progress, :map, required: true
  attr :myself, :any, required: true

  defp settings(assigns) do
    ~H"""
    <p class="text-tymeslot-600 max-w-2xl">
      {dgettext(
        "dashboard_languages",
        "Choose the language you write your booking pages in, and translate your texts into other languages. These settings apply to every booking page."
      )}
    </p>

    <.card
      title={dgettext("dashboard_languages", "Original language")}
      description={dgettext("dashboard_languages", "The language your texts are written in.")}
      icon="hero-pencil-square"
    >
      <.form
        for={%{}}
        id="original-language-form"
        novalidate
        phx-change="set_original"
        phx-target={@myself}
      >
        <.select
          id="content-locale"
          name="content_locale"
          value={@original}
          options={Labels.language_options(@locales)}
          aria-label={dgettext("dashboard_languages", "Original language")}
        />
      </.form>
    </.card>

    <.card
      title={dgettext("dashboard_languages", "Translations")}
      description={
        dgettext(
          "dashboard_languages",
          "Visitors who choose one of these languages see your texts translated. A text you leave untranslated shows in the original."
        )
      }
      icon="hero-language"
    >
      <div class="space-y-6">
        <ul
          :if={@locales != []}
          class="divide-y divide-tymeslot-100"
          data-testid="translation-languages"
        >
          <li
            :for={code <- @locales}
            class="flex flex-wrap items-center justify-between gap-3 py-3"
            data-locale={code}
          >
            <div class="flex items-center gap-3 min-w-0">
              <.locale_flag locale={code} class="w-6 h-4" />
              <span class="font-bold text-tymeslot-800">{Labels.language_name(code)}</span>
              <.progress_summary progress={@progress[code]} />
            </div>
            <div class="flex items-center gap-2">
              <.action_link
                patch={~p"/dashboard/languages/#{code}"}
                variant={:secondary}
                size={:sm}
                icon="hero-pencil-square"
              >
                {dgettext("dashboard_languages", "Review")}
              </.action_link>
              <.icon_button
                icon="hero-trash"
                variant={:danger}
                size={:sm}
                label={
                  dgettext("dashboard_languages", "Remove %{language}",
                    language: Labels.language_name(code)
                  )
                }
                phx-click="remove_locale"
                phx-value-locale={code}
                phx-target={@myself}
                data-testid={"remove-locale-#{code}"}
              />
            </div>
          </li>
        </ul>

        <p :if={@locales == []} class="text-token-sm text-tymeslot-500">
          {dgettext("dashboard_languages", "No translations yet.")}
        </p>

        <.form
          :if={Labels.language_options([@original | @locales]) != []}
          for={%{}}
          id="add-language-form"
          novalidate
          phx-change="add_locale"
          phx-target={@myself}
        >
          <.select
            id="add-translation-locale"
            name="locale"
            value=""
            prompt={dgettext("dashboard_languages", "Add a translation…")}
            options={Labels.language_options([@original | @locales])}
            label={dgettext("dashboard_languages", "Add translation")}
          />
        </.form>
      </div>
    </.card>

    <.card
      title={dgettext("dashboard_languages", "Booking page languages")}
      icon="hero-globe-alt"
    >
      <div class="space-y-4">
        <.setting_row
          id="offer-all-locales"
          control={:switch}
          label={dgettext("dashboard_languages", "Show the booking page in all languages")}
          description={
            dgettext(
              "dashboard_languages",
              "Visitors in other languages see your texts in %{language}; buttons, dates and emails are translated.",
              language: Labels.language_name(@original)
            )
          }
          checked={@offer_all}
          on_change="toggle_offer_all"
          target={@myself}
        />
        <.info_box :if={not @offer_all and @locales == []} variant={:info}>
          {dgettext(
            "dashboard_languages",
            "Your booking page is offered only in %{language}, so visitors see no language switcher. Add a translation to offer another language.",
            language: Labels.language_name(@original)
          )}
        </.info_box>
        <.info_box :if={not @offer_all and @locales != []} variant={:info}>
          {dgettext(
            "dashboard_languages",
            "Your booking page is offered only in %{language} and your translation languages.",
            language: Labels.language_name(@original)
          )}
        </.info_box>
      </div>
    </.card>
    """
  end

  attr :progress, :map, default: nil

  defp progress_summary(%{progress: nil} = assigns), do: ~H""

  defp progress_summary(assigns) do
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

  attr :locale, :string, required: true
  attr :progress, :map, default: nil
  attr :items, :map, default: nil
  attr :only_open, :boolean, required: true
  attr :user_id, :integer, required: true
  attr :myself, :any, required: true

  defp review(assigns) do
    assigns =
      assign(assigns, :sections, sections(assigns.items, assigns.locale, assigns.only_open))

    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-4">
      <div class="flex items-center gap-3">
        <.locale_flag locale={@locale} class="w-8 h-6" />
        <.subsection_header
          level={2}
          size={:lg}
          title={
            dgettext("dashboard_languages", "%{language} translations",
              language: Labels.language_name(@locale)
            )
          }
        />
        <.progress_summary progress={@progress} />
      </div>
      <.action_link
        patch={~p"/dashboard/languages"}
        variant={:ghost}
        size={:sm}
        icon="hero-arrow-left"
      >
        {dgettext("dashboard_languages", "All languages")}
      </.action_link>
    </div>

    <.setting_row
      id="only-open-translations"
      control={:switch}
      label={dgettext("dashboard_languages", "Only missing or outdated")}
      checked={@only_open}
      on_change="toggle_only_open"
      target={@myself}
    />

    <.empty_state
      :if={@items && @sections == []}
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
      <.card :for={entity <- entities} title={entity_title(group, entity)}>
        <.live_component
          module={TranslationEditor}
          id={"translation-#{group}-#{entity.kind}-#{entity.id}"}
          user_id={@user_id}
          kind={entity.kind}
          record={entity.record}
          locale={@locale}
          paths={Enum.map(entity.fields, & &1.path)}
          only_open={@only_open}
          notify={{__MODULE__, "languages"}}
        />
      </.card>
    </section>
    """
  end

  # The groups with something to show, each with its records that have.
  defp sections(nil, _locale, _only_open), do: []

  defp sections(items, locale, only_open) do
    for group <- @groups,
        entities = Enum.filter(items[group], &shows?(&1, locale, only_open)),
        entities != [],
        do: {group, entities}
  end

  defp shows?(entity, locale, only_open) do
    TranslationEditor.visible_fields(entity.record, locale,
      paths: Enum.map(entity.fields, & &1.path),
      only_open: only_open
    ) != []
  end

  defp group_title(:booking_texts), do: dgettext("dashboard_languages", "Booking page texts")
  defp group_title(:intro), do: dgettext("dashboard_languages", "About you")
  defp group_title(:meeting_types), do: dgettext("dashboard_languages", "Meeting types")
  defp group_title(:venues), do: dgettext("dashboard_languages", "Locations")

  defp entity_title(:booking_texts, %{kind: :profile}),
    do: dgettext("dashboard_languages", "Your booking page")

  defp entity_title(:intro, _entity), do: dgettext("dashboard_languages", "Headline and bio")
  defp entity_title(_group, %{name: name}), do: name
end
