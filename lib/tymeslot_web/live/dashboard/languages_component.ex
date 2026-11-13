defmodule TymeslotWeb.Dashboard.LanguagesComponent do
  @moduledoc """
  The Languages page, in two tabs (`<.tab_bar>`):

    * **Settings**, at `/dashboard/languages` (`SettingsTab`): the original
      language, the languages invitees can choose (ticking one makes it a
      translation language) and whether every other language is offered too,
      saved through `Tymeslot.Profiles.update_booking_languages/2`.
    * **Translations**, at `/dashboard/languages/:language`
      (`TranslationsTab`): a flag tab per translation language, and every
      translatable record (`Tymeslot.ContentTranslations.Catalogue.items/1`)
      with a `TranslationEditor` each, the one place translations are
      written. The forms that edit the originals link here
      (`TranslationStatus`), with `?item=` naming the record's card, which
      is highlighted, and the same as a fragment, which the browser scrolls
      to.

  Unticking a translation language asks first (`RemoveLanguageModal`); its
  texts are kept, so ticking the language again brings them back.

  Switching tab or language, or turning "Only missing or outdated" on or off
  (which takes away the editors of what is then hidden), first has every
  editor on the page save what was typed in it (`TranslationEditor.leave/2`);
  the page moves on once each has, and stays where it is if one could not.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.ContentTranslations.Languages
  alias Tymeslot.Locales
  alias Tymeslot.Profiles
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Dashboard.Languages.RemoveLanguageModal
  alias TymeslotWeb.Dashboard.Languages.SettingsTab
  alias TymeslotWeb.Dashboard.Languages.TranslationEditor
  alias TymeslotWeb.Dashboard.Languages.TranslationsTab

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
       review_locale: nil,
       pending: nil
     )}
  end

  # A saved translation changes only its own record, so it replaces that
  # record in the items already read and the progress is counted again from
  # them, without reading everything back.
  @impl Phoenix.LiveComponent
  def update(%{translation_saved: entity}, %{assigns: %{items: %{} = items}} = socket) do
    socket = socket |> refresh_profile() |> assign(:items, replace_record(items, entity))
    {:ok, count_progress(socket)}
  end

  def update(%{translation_saved: _entity}, socket),
    do: {:ok, socket |> refresh_profile() |> load()}

  # One editor has saved what was typed in it before `action`; the last one
  # to do so runs it.
  def update(%{drafts_saved: {action, editor}}, socket) do
    case socket.assigns.pending do
      {^action, editors} ->
        editors = MapSet.delete(editors, editor)

        if MapSet.size(editors) == 0,
          do: {:ok, socket |> assign(:pending, nil) |> run(action)},
          else: {:ok, assign(socket, :pending, {action, editors})}

      _other ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    locales = Languages.translatable(socket.assigns.profile)
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

  # The first translation saved in a language makes it one of the
  # organiser's (`Catalogue.save/5`), so the profile is read again.
  defp refresh_profile(socket) do
    case Profiles.get_profile_by_user_id(socket.assigns.current_user.id) do
      {:ok, profile} ->
        if profile.translation_locales != socket.assigns.profile.translation_locales,
          do: send(self(), {:profile_updated, profile})

        assign(socket, :profile, profile)

      {:error, :not_found} ->
        socket
    end
  end

  # One read of everything translatable, from which every language's
  # progress is counted.
  defp load(socket) do
    socket
    |> assign(:items, Catalogue.items(socket.assigns.current_user.id))
    |> count_progress()
  end

  defp count_progress(%{assigns: %{items: items, profile: profile}} = socket),
    do: assign(socket, :progress, Catalogue.progress(items, Languages.translatable(profile)))

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
  def handle_event("set_original", %{"locale" => code}, socket) do
    profile = socket.assigns.profile

    # A ticked language made the original stays ticked (`Languages.chosen/1`),
    # so making another one the original again changes nothing else.
    if code == Languages.original(profile),
      do: {:noreply, socket},
      else: {:noreply, save(socket, %{content_locale: code})}
  end

  # Ticking a language adds it; unticking asks first (`RemoveLanguageModal`).
  def handle_event("toggle_locale", %{"locale" => code}, socket) do
    profile = socket.assigns.profile
    locales = Languages.translation_locales(profile)

    cond do
      code == Languages.original(profile) ->
        {:noreply, socket}

      code in locales ->
        {:noreply, assign(socket, :removing_locale, code)}

      code in Locales.supported_codes() ->
        {:noreply, save(socket, %{translation_locales: Languages.chosen(profile) ++ [code]})}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_offer_all", _params, socket) do
    offer_all = not Languages.restricted?(socket.assigns.profile)
    {:noreply, save(socket, %{offer_all_locales: not offer_all})}
  end

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, :removing_locale, nil)}

  def handle_event("confirm_remove", _params, %{assigns: %{removing_locale: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_remove", _params, %{assigns: %{removing_locale: code}} = socket) do
    locales = Languages.chosen(socket.assigns.profile) -- [code]

    {:noreply,
     socket
     |> assign(:removing_locale, nil)
     |> save(%{translation_locales: locales})}
  end

  def handle_event("switch_tab", %{"tab" => "settings"}, socket),
    do: {:noreply, after_drafts_saved(socket, {:patch, ~p"/dashboard/languages"})}

  def handle_event("switch_tab", %{"tab" => "translations"}, socket) do
    case first_language(socket.assigns) do
      nil -> {:noreply, socket}
      code -> {:noreply, after_drafts_saved(socket, {:patch, ~p"/dashboard/languages/#{code}"})}
    end
  end

  def handle_event("switch_tab", _params, socket), do: {:noreply, socket}

  def handle_event("switch_language", %{"tab" => code}, socket) do
    if code in Languages.translatable(socket.assigns.profile),
      do: {:noreply, after_drafts_saved(socket, {:patch, ~p"/dashboard/languages/#{code}"})},
      else: {:noreply, socket}
  end

  def handle_event("toggle_only_open", _params, socket),
    do: {:noreply, after_drafts_saved(socket, :toggle_only_open)}

  # The language with the most left to translate, so the tab opens where
  # there is work; the first one when everything is done.
  # Among the organiser's own languages first: offering every language,
  # the rest are all untouched.
  defp first_language(%{profile: profile, progress: progress}) do
    case {Languages.translation_locales(profile), Languages.translatable(profile)} do
      {[], []} -> nil
      {[], [first | _rest]} -> first
      {own, _all} -> Enum.max_by(own, &TranslationsTab.open_count(progress[&1]))
    end
  end

  defp after_drafts_saved(socket, action) do
    case editor_ids(socket.assigns) do
      [] ->
        run(socket, action)

      ids ->
        myself = socket.assigns.myself

        for id <- ids do
          TranslationEditor.leave(id, fn ->
            send_update(myself, drafts_saved: {action, id})
          end)
        end

        assign(socket, :pending, {action, MapSet.new(ids)})
    end
  end

  defp run(socket, :toggle_only_open), do: update(socket, :only_open, &(not &1))

  defp run(socket, {:patch, path}) do
    send(self(), {:patch, path})
    socket
  end

  defp editor_ids(%{review_locale: locale, items: items, only_open: only_open})
       when is_binary(locale) do
    for {group, entities} <- sections(items, locale, only_open),
        entity <- entities,
        do: editor_id(group, entity)
  end

  defp editor_ids(_assigns), do: []

  defp editor_id(group, entity), do: "translation-#{group}-#{entity.kind}-#{entity.id}"

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
    locales = Languages.translatable(socket.assigns.profile)
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
    original = Languages.original(assigns.profile)
    locales = Languages.translation_locales(assigns.profile)

    assigns =
      assign(assigns,
        original: original,
        # While a language waits on "Remove?", its box shows unticked, as the
        # click left it; cancelling ticks it again.
        locales: locales -- [assigns.removing_locale],
        chosen: locales,
        all_locales: Languages.translatable(assigns.profile),
        offer_all: not Languages.restricted?(assigns.profile),
        active_tab: if(assigns.review_locale, do: "translations", else: "settings"),
        open: Enum.sum_by(locales, &TranslationsTab.open_count(assigns.progress[&1]))
      )

    ~H"""
    <div>
      <.dashboard_page icon="hero-language" title={dgettext("dashboard_languages", "Languages")}>
        <p class="text-tymeslot-600 max-w-2xl">
          {dgettext(
            "dashboard_languages",
            "Choose which languages invitees can see your booking pages in, then translate your texts into them. This applies to every booking page."
          )}
        </p>

        <.tab_bar
          id="languages-tabs"
          active_tab={@active_tab}
          tabs={top_tabs(@all_locales, @open)}
          target={@myself}
          aria_label={dgettext("dashboard_languages", "Languages")}
        />
        <p :if={@all_locales == []} id="translations-tab-hint" class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_languages",
            "Tick a language under Booking page languages to translate your texts into it."
          )}
        </p>

        <div
          role="tabpanel"
          id={Navigation.panel_id("languages-tabs", @active_tab)}
          aria-labelledby={Navigation.tab_id("languages-tabs", @active_tab)}
          class="space-y-6"
        >
          <%= if @review_locale do %>
            <TranslationsTab.translations_tab
              locale={@review_locale}
              locales={@all_locales}
              chosen={@chosen}
              original={@original}
              progress={@progress}
              sections={sections(@items, @review_locale, @only_open)}
              loaded={@items != nil}
              only_open={@only_open}
              user_id={@current_user.id}
              item={(@params || %{})["item"]}
              editor_id={&editor_id/2}
              notify={{__MODULE__, "languages"}}
              myself={@myself}
            />
          <% else %>
            <SettingsTab.settings_tab
              original={@original}
              locales={@locales}
              offer_all={@offer_all}
              progress={@progress}
              myself={@myself}
            />
          <% end %>
        </div>
      </.dashboard_page>

      <RemoveLanguageModal.remove_language_modal
        :if={@removing_locale}
        locale={@removing_locale}
        myself={@myself}
      />
    </div>
    """
  end

  defp top_tabs(locales, open) do
    translations = %{
      id: "translations",
      label: dgettext("dashboard_languages", "Translations"),
      icon: "hero-language"
    }

    translations =
      cond do
        locales == [] ->
          Map.merge(translations, %{disabled: true, describedby: "translations-tab-hint"})

        open > 0 ->
          Map.merge(translations, %{
            status: :warning,
            status_label: dgettext("dashboard_languages", "Some texts still need translating")
          })

        true ->
          translations
      end

    [
      %{
        id: "settings",
        label: dgettext("dashboard_languages", "Settings"),
        icon: "hero-cog-6-tooth"
      },
      translations
    ]
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
end
