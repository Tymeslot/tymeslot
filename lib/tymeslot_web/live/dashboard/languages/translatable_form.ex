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
  texts typed in it first. Leaving the original hands it to the host's
  `:save_original` component, when the host saves by hand, so that what it
  typed is saved before it is translated. Closing the host goes through
  `leave/2`, so a translation typed and not yet saved is saved too.

  ## Assigns

    * `:profile` - for the booking languages;
    * `:editing_locale` - the dashboard's editing language, or nil;
    * `:user_id`, `:kind`, `:record` - the record the form edits;
    * `:paths` - only these of its texts (a card editing part of a record);
    * `:save_original` - the host component (its `@myself`) to hand a switch
      from the original to: it is sent `save_original: locale`, saves what
      was typed if anything, and then sends `{:editing_locale, locale}`
      itself. Left out (an autosaving form), the switch is immediate;
    * `:inner_block` - the form, in the original language; a host that
      keeps its form mounted while translating (hidden, with
      `translating?/2`) leaves it out;
    * `:actions` - shown under the editor, such as the form's Done button;
    * `:class` - layout classes for the bar and editor, applied only while
      the bar shows.

  The record's translations are read from the database when the form opens
  and again whenever the editing language changes (one read of one record),
  so a translation saved elsewhere, in another tab or on the Languages page,
  is never shown stale; between reads they are kept from each save. No form
  casts `translations`, so the copy a host form holds can be older than what
  was saved, and only its originals are taken from it.
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

  @doc """
  Has the form `id` save a translation typed in its editor, if one is open,
  and then run `continue` (in the LiveView process), such as closing the
  form. With the original shown, `continue` runs at once: the host owns that
  draft. Call it only while the form is rendered.
  """
  @spec leave(String.t(), (-> any())) :: :ok
  def leave(id, continue) when is_function(continue, 0),
    do: send_update(__MODULE__, id: id, leave: continue)

  @impl Phoenix.LiveComponent
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         translations: nil,
         read_for: :unread,
         current: nil,
         paths: nil,
         actions: [],
         inner_block: [],
         class: nil,
         save_original: nil
       )}

  @impl Phoenix.LiveComponent
  def update(%{translation_saved: %{record: saved}}, socket),
    do: {:ok, socket |> assign(:translations, saved.translations) |> derive()}

  def update(%{leave: continue}, socket) do
    if socket.assigns.current,
      do: TranslationEditor.leave("#{socket.assigns.id}-editor", :close, continue),
      else: continue.()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    %{profile: profile} = socket.assigns

    current =
      if translating?(profile, socket.assigns[:editing_locale]), do: socket.assigns.editing_locale

    # Read again on each change of language: cheap, and what another tab or
    # the Languages page saved meanwhile shows in the editor about to open.
    socket =
      if Languages.translation_locales(profile) != [] and socket.assigns.read_for != current,
        do:
          assign(socket,
            translations: stored_translations(socket.assigns),
            read_for: current
          ),
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
        Map.new(locales, fn locale ->
          {locale,
           length(
             TranslationEditor.visible_fields(record, locale,
               paths: assigns.paths,
               only_open: true
             )
           )}
        end)
    )
  end

  @impl Phoenix.LiveComponent
  # Leaving a translation goes through its editor, which saves what was
  # typed in it before the dashboard switches (`TranslationEditor`); leaving
  # the original of a form saved by hand goes through the host, which saves
  # its own draft first.
  def handle_event("choose_editing_locale", %{"locale" => locale}, socket) do
    %{id: id, current: current, locales: locales, save_original: host} = socket.assigns
    target = if locale in locales, do: locale

    cond do
      target == current ->
        :ok

      current ->
        TranslationEditor.leave("#{id}-editor", :switch, fn ->
          send(self(), {:editing_locale, target})
        end)

      host ->
        send_update(host, save_original: target)

      true ->
        send(self(), {:editing_locale, target})
    end

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
