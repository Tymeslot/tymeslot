defmodule TymeslotWeb.Dashboard.Languages.TranslatableForm do
  @moduledoc """
  Wraps a dashboard form whose record can be translated (the meeting type
  editor, the booking page text card, the profile intro card, the venue
  modal) with the language bar, and swaps the form for the
  `TranslationEditor` while a translation language is being edited.

  The editing language is the dashboard's, not the form's: choosing one
  sends `{:editing_locale, code}` to `DashboardLive`
  (`TymeslotWeb.Hooks.EditingLocaleHook`), which hands it back down as
  `:editing_locale`, so it carries over to every other translatable form.
  It is ignored while it is not one of the profile's translation languages.
  With no translation language at all, the form renders on its own. Leaving
  a translation language hands the switch to the editor, which saves the
  texts typed in it first.

  ## Assigns

    * `:profile` - for the booking languages;
    * `:editing_locale` - the dashboard's editing language, or nil;
    * `:user_id`, `:kind`, `:record` - the record the form edits;
    * `:paths` - only these of its texts (a card editing part of a record);
    * `:inner_block` - the form, in the original language; a host that
      keeps its form mounted while translating (hidden, with
      `translating?/2`) leaves it out;
    * `:actions` - shown under the editor, such as the form's Done button;
    * `:class` - layout classes for the bar and editor, applied only while
      the bar shows.

  The record's translations are read from the database when the form opens,
  and kept from each save: no form casts `translations`, so the copy a host
  form holds can be older than what was saved, and only its originals are
  taken from it.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ContentTranslations.Catalogue
  alias Tymeslot.ContentTranslations.Languages
  alias TymeslotWeb.Dashboard.Languages.LanguageBar
  alias TymeslotWeb.Dashboard.Languages.TranslationEditor

  @doc """
  Whether a form under the language bar is showing the translation editor:
  the editing language is one of the profile's translation languages.
  """
  @spec translating?(map() | nil, String.t() | nil) :: boolean()
  def translating?(profile, editing_locale),
    do: is_binary(editing_locale) and editing_locale in Languages.translation_locales(profile)

  @impl Phoenix.LiveComponent
  def mount(socket),
    do:
      {:ok,
       assign(socket, translations: nil, paths: nil, actions: [], inner_block: [], class: nil)}

  @impl Phoenix.LiveComponent
  def update(%{translation_saved: %{record: saved}}, socket),
    do: {:ok, socket |> assign(:translations, saved.translations) |> derive()}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    locales = Languages.translation_locales(socket.assigns.profile)

    socket =
      if is_nil(socket.assigns.translations) and locales != [],
        do: assign(socket, :translations, stored_translations(socket.assigns)),
        else: socket

    {:ok, derive(socket)}
  end

  defp stored_translations(%{user_id: user_id, kind: kind, record: record}) do
    case Catalogue.get(user_id, {kind, record.id}) do
      {:ok, %{record: stored}} -> stored.translations
      {:error, :not_found} -> record.translations
    end
  end

  defp derive(%{assigns: assigns} = socket) do
    locales = Languages.translation_locales(assigns.profile)
    record = %{assigns.record | translations: assigns.translations || assigns.record.translations}

    assign(socket,
      locales: locales,
      original: Languages.original(assigns.profile),
      current:
        if(translating?(assigns.profile, assigns[:editing_locale]), do: assigns.editing_locale),
      translated_record: record,
      open:
        Enum.filter(locales, fn locale ->
          TranslationEditor.visible_fields(record, locale, paths: assigns.paths, only_open: true) !=
            []
        end)
    )
  end

  @impl Phoenix.LiveComponent
  # Leaving a translation goes through its editor, which saves what was
  # typed in it before the dashboard switches (`TranslationEditor`).
  def handle_event("choose_editing_locale", %{"locale" => locale}, socket) do
    %{id: id, current: current, locales: locales} = socket.assigns
    target = if locale in locales, do: locale

    if current && target != current,
      do: send_update(TranslationEditor, id: "#{id}-editor", switch_to: target),
      else: send(self(), {:editing_locale, target})

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} class={@locales != [] && ["space-y-6", @class]}>
      <LanguageBar.language_bar
        :if={@locales != []}
        id={"#{@id}-bar"}
        original={@original}
        locales={@locales}
        current={@current}
        open={@open}
        target={@myself}
      />
      <%= if @current do %>
        <.live_component
          module={TranslationEditor}
          id={"#{@id}-editor"}
          user_id={@user_id}
          kind={@kind}
          record={@translated_record}
          locale={@current}
          paths={@paths}
          notify={{__MODULE__, @id}}
        />
        {render_slot(@actions)}
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </div>
    """
  end
end
