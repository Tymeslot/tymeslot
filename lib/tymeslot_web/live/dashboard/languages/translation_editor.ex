defmodule TymeslotWeb.Dashboard.Languages.TranslationEditor do
  @moduledoc """
  The translations of one record into one language: for each of its texts
  with an original, the field's label, the original, an input for the
  translation and how it stands (Missing, Outdated or Translated). Saved per
  record with one button, through `Tymeslot.ContentTranslations.Catalogue`.

  Used for every record on the Languages review page, and in context by
  `TymeslotWeb.Dashboard.Languages.TranslatableForm`, which swaps a form's
  body for it while the organiser edits in a translation language.

  ## Assigns

    * `:user_id`, `:kind` and `:record` - whose translations, and which
      record (`Catalogue.entity/0`'s `kind` and `record`);
    * `:locale` - the translation language;
    * `:paths` - only these texts of the record (a card that edits part of
      it), or nil for all of them;
    * `:only_open` - show only the texts still missing or outdated;
    * `:notify` - `{module, id}` of a component told
      `translation_saved: entity` after each save, so it can refresh what it
      shows from the saved record.

  Only the texts the organiser changed are sent as texts on save; an
  outdated one left as it was is confirmed rather than rewritten (below).
  Leaving the editor saves the changed texts alone, so a translation left
  as it was keeps its Outdated mark there. What is typed survives the parent re-rendering; it is dropped
  only when it is saved, or when the record or the language changes.

  Anything that takes the editor away (another language from the language
  bar, closing the form it sits in, leaving or filtering the Languages
  review page) goes through `leave/3`, so what was typed is not lost: the
  changed texts are saved first, as the autosaving forms save theirs, and
  only then does the caller carry on. When that save fails the editor stays,
  showing why; asking to leave again leaves without saving.

  An outdated translation is hidden from invitees, who see the original
  instead, until it is updated or confirmed as still correct (`Catalogue.confirm/4`),
  which each outdated text offers beside its input. Save confirms it too
  when its input still holds the stored translation: saving says what the
  form shows is correct.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ContentTranslations
  alias Tymeslot.ContentTranslations.Catalogue
  alias TymeslotWeb.Components.CoreComponents.Forms
  alias TymeslotWeb.Dashboard.Languages.Labels

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     assign(socket,
       draft: %{},
       errors: %{},
       leave_unsaved: false,
       paths: nil,
       only_open: false,
       notify: nil
     )}
  end

  @doc """
  Asks the editor `id` to save what was typed in it, then to run `continue`
  (in the LiveView process): `reason` is `:switch` for another language from
  the language bar, `:close` for closing the form the editor sits in, and
  `:review` for leaving or filtering the Languages review page, and only
  words the message shown when the save fails. Nothing typed, `continue`
  runs at once.
  """
  @spec leave(String.t(), :switch | :close | :review, (-> any())) :: :ok
  def leave(id, reason, continue) when is_function(continue, 0),
    do: send_update(__MODULE__, id: id, leave: {reason, continue})

  @impl Phoenix.LiveComponent
  def update(%{leave: {reason, continue}}, socket) do
    %{draft: draft, record: record, locale: locale, fields: fields} = socket.assigns
    changed = changed_texts(draft, record, locale, fields)

    if changed == %{} or socket.assigns.leave_unsaved do
      continue.()
      {:ok, assign(socket, :leave_unsaved, false)}
    else
      case persist(socket, changed, draft) do
        {:ok, socket} ->
          Flash.info(dgettext("dashboard_languages", "Translations saved"))
          continue.()
          {:ok, socket}

        {:error, socket} ->
          Flash.error(leave_failed_message(reason))
          {:ok, assign(socket, :leave_unsaved, true)}
      end
    end
  end

  def update(assigns, socket) do
    socket =
      if switched?(socket.assigns, assigns),
        do: assign(socket, draft: %{}, errors: %{}),
        else: socket

    {:ok, socket |> assign(assigns) |> assign_fields()}
  end

  defp switched?(%{record: %{id: id}, locale: locale}, %{record: %{id: id}, locale: locale}),
    do: false

  defp switched?(%{record: _record}, _assigns), do: true
  defp switched?(_assigns, _new), do: false

  defp assign_fields(%{assigns: assigns} = socket) do
    assign(
      socket,
      :fields,
      visible_fields(assigns.record, assigns.locale,
        paths: assigns.paths,
        only_open: assigns.only_open
      )
    )
  end

  @doc """
  The texts of `record` the editor shows for `locale`, each with its status:
  every text with an original (`:paths` limits them), or with `only_open:
  true` only those missing or outdated.
  """
  @spec visible_fields(struct(), String.t(), keyword()) :: [
          {ContentTranslations.field(), ContentTranslations.status()}
        ]
  def visible_fields(record, locale, opts \\ []) do
    paths = Keyword.get(opts, :paths)
    wanted = if Keyword.get(opts, :only_open, false), do: [:missing, :outdated]

    for field <- ContentTranslations.fields(record),
        is_nil(paths) or field.path in paths,
        status = ContentTranslations.field_status(record, field, locale),
        status != :not_needed,
        is_nil(wanted) or status in wanted,
        do: {field, status}
  end

  @impl Phoenix.LiveComponent
  def handle_event("draft", %{"translation" => texts}, socket) when is_map(texts) do
    {:noreply,
     socket
     |> update(:draft, &Map.merge(&1, only_strings(texts)))
     |> assign(:leave_unsaved, false)}
  end

  def handle_event("draft", _params, socket), do: {:noreply, socket}

  def handle_event("confirm", %{"path" => path}, socket) when is_binary(path) do
    if confirmable?(socket.assigns, path),
      do: {:noreply, confirm(socket, path)},
      else: {:noreply, socket}
  end

  def handle_event("save", params, socket) do
    %{draft: draft, record: record, locale: locale} = socket.assigns
    typed = Map.merge(draft, only_strings(Map.get(params, "translation", %{})))
    changed = changed_texts(typed, record, locale, socket.assigns.fields)
    kept = kept_outdated(%{socket.assigns | draft: typed}, changed)

    if changed == %{} and kept == [] do
      Flash.info(dgettext("dashboard_languages", "Nothing to save: no translation changed."))
      {:noreply, assign(socket, :draft, typed)}
    else
      save(socket, changed, typed, kept)
    end
  end

  # Saving says the form is right as it stands, so an outdated text whose
  # input still holds its stored translation is confirmed along with the
  # texts that changed (`Catalogue.save/5`'s `confirm:`).
  defp kept_outdated(assigns, changed) do
    for {field, :outdated} <- assigns.fields,
        not Map.has_key?(changed, field.path),
        confirmable?(assigns, field.path),
        do: field.path
  end

  defp save(socket, changed, typed, kept) do
    case persist(socket, changed, typed, kept) do
      {:ok, socket} ->
        Flash.info(dgettext("dashboard_languages", "Translations saved"))
        {:noreply, socket}

      {:error, socket} ->
        Flash.error(dgettext("dashboard_languages", "Couldn't save these translations."))
        {:noreply, socket}
    end
  end

  defp confirm(socket, path) do
    %{user_id: user_id, kind: kind, record: record, locale: locale} = socket.assigns

    case Catalogue.confirm(user_id, {kind, record.id}, locale, [path]) do
      {:ok, entity} ->
        notify(socket.assigns.notify, entity)
        Flash.info(dgettext("dashboard_languages", "Translation kept"))

        socket
        |> assign(
          record: entity.record,
          draft: Map.delete(socket.assigns.draft, path),
          errors: Map.delete(socket.assigns.errors, path)
        )
        |> assign_fields()

      {:error, :not_found} ->
        assign(socket, :errors, %{base: [not_found_message()]})

      {:error, changeset} ->
        Flash.error(dgettext("dashboard_languages", "Couldn't keep this translation."))
        assign(socket, :errors, errors_by_path(changeset))
    end
  end

  # An outdated text whose stored translation is still what its input shows:
  # confirming keeps the stored text, so it is offered only while nothing
  # different has been typed over it.
  defp confirmable?(%{fields: fields, draft: draft, record: record, locale: locale}, path) do
    stored = ContentTranslations.translation(record, locale, path)

    Enum.any?(fields, fn {field, status} -> field.path == path and status == :outdated end) and
      is_binary(stored) and normalise(Map.get(draft, path, stored)) == normalise(stored)
  end

  defp persist(socket, changed, typed, kept \\ []) do
    %{user_id: user_id, kind: kind, record: record, locale: locale} = socket.assigns

    case Catalogue.save(user_id, {kind, record.id}, locale, changed, confirm: kept) do
      {:ok, entity} ->
        notify(socket.assigns.notify, entity)

        {:ok,
         socket
         |> assign(
           record: entity.record,
           draft: Map.drop(typed, Map.keys(changed) ++ kept),
           errors: %{},
           leave_unsaved: false
         )
         |> assign_fields()}

      {:error, :not_found} ->
        {:error, assign(socket, draft: typed, errors: %{base: [not_found_message()]})}

      {:error, changeset} ->
        {:error, assign(socket, draft: typed, errors: errors_by_path(changeset))}
    end
  end

  defp not_found_message, do: dgettext("dashboard_languages", "This item no longer exists.")

  defp leave_failed_message(:switch),
    do:
      dgettext(
        "dashboard_languages",
        "Couldn't save these translations. Choose the language again to leave without saving them."
      )

  defp leave_failed_message(_reason),
    do:
      dgettext(
        "dashboard_languages",
        "Couldn't save these translations. Try again to leave without saving them."
      )

  defp notify({module, id}, entity), do: send_update(module, id: id, translation_saved: entity)
  defp notify(nil, _entity), do: :ok

  # The texts that differ from what is stored, a cleared one included (which
  # deletes it). Only the record's own shown texts can be sent.
  defp changed_texts(typed, record, locale, fields) do
    shown = MapSet.new(fields, fn {field, _status} -> field.path end)

    for {path, text} <- typed,
        path in shown,
        normalise(text) != (ContentTranslations.translation(record, locale, path) || ""),
        into: %{},
        do: {path, text}
  end

  # As `ContentTranslations.put/4` stores it, so a textarea's CRLF line
  # breaks do not count as an edit.
  defp normalise(text), do: text |> String.replace("\r\n", "\n") |> String.trim()

  defp only_strings(texts) when is_map(texts),
    do:
      for({path, text} <- texts, is_binary(path) and is_binary(text), into: %{}, do: {path, text})

  defp only_strings(_texts), do: %{}

  # A text that could not be saved names its path on the error; any other
  # error belongs to the whole record.
  defp errors_by_path(changeset) do
    Enum.group_by(
      changeset.errors,
      fn {_field, {_message, opts}} -> Keyword.get(opts, :path, :base) end,
      fn {_field, error} -> error end
    )
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} data-testid="translation-editor">
      <%= if @fields == [] do %>
        <p class="text-token-sm text-tymeslot-500">
          <%= if @only_open do %>
            {dgettext("dashboard_languages", "Everything here is translated.")}
          <% else %>
            {dgettext("dashboard_languages", "Nothing here to translate yet.")}
          <% end %>
        </p>
      <% else %>
        <.form
          for={%{}}
          as={:translation}
          id={"#{@id}-form"}
          novalidate
          phx-change="draft"
          phx-submit="save"
          phx-target={@myself}
          class="space-y-6"
        >
          <.translation_field
            :for={{field, status} <- @fields}
            id={"#{@id}-#{field_id(field.path)}"}
            field={field}
            status={status}
            value={
              Map.get(
                @draft,
                field.path,
                ContentTranslations.translation(@record, @locale, field.path)
              )
            }
            errors={Map.get(@errors, field.path, [])}
            confirmable={confirmable?(assigns, field.path)}
            target={@myself}
          />
          <Forms.field_error errors={Map.get(@errors, :base, [])} />
          <div class="flex justify-end">
            <.loading_button
              type="submit"
              icon="hero-check"
              phx-disable-with={dgettext("dashboard_languages", "Saving…")}
              data-testid="save-translations"
            >
              {dgettext("dashboard_languages", "Save translations")}
            </.loading_button>
          </div>
        </.form>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field, :map, required: true
  attr :status, :atom, required: true
  attr :value, :string, default: nil
  attr :errors, :list, default: []
  attr :confirmable, :boolean, default: false
  attr :target, :any, required: true

  defp translation_field(assigns) do
    ~H"""
    <div data-path={@field.path} data-status={@status}>
      <.input
        id={@id}
        name={"translation[#{@field.path}]"}
        type={if @field.multiline, do: "textarea", else: "text"}
        rows={4}
        value={@value}
        maxlength={@field.max_length}
        label={label(@field)}
        errors={@errors}
        phx-debounce="300"
      >
        <:description>
          <span class="flex items-start justify-between gap-3">
            <span class="flex-1 min-w-0 whitespace-pre-line break-words">{original_line(@field)}</span>
            <span class="shrink-0"><.status_badge status={@status} /></span>
          </span>
        </:description>
      </.input>
      <div
        :if={@status == :outdated}
        class="mt-2 flex flex-wrap items-center justify-between gap-3"
        data-testid="outdated-note"
      >
        <p class="flex-1 min-w-0 text-token-sm text-tymeslot-600">
          {dgettext(
            "dashboard_languages",
            "Invitees see the original until you update this translation or confirm it is still correct."
          )}
        </p>
        <.action_button
          :if={@confirmable}
          variant={:secondary}
          size={:sm}
          icon="hero-check"
          phx-click="confirm"
          phx-value-path={@field.path}
          phx-target={@target}
          data-testid="confirm-translation"
        >
          {dgettext("dashboard_languages", "Still correct")}
        </.action_button>
      </div>
    </div>
    """
  end

  # On one line in the template: the span keeps line breaks, so the
  # template's own would show as a blank first line.
  defp original_line(field),
    do: dgettext("dashboard_languages", "Original: %{text}", text: field.original)

  attr :status, :atom, required: true

  @doc "The Missing, Outdated or Translated pill for a text's status."
  @spec status_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def status_badge(%{status: :translated} = assigns) do
    ~H"""
    <.pill tone={:success} dot data-testid="translation-status">
      {dgettext("dashboard_languages", "Translated")}
    </.pill>
    """
  end

  def status_badge(%{status: :outdated} = assigns) do
    ~H"""
    <.pill tone={:warning} dot data-testid="translation-status">
      {dgettext("dashboard_languages", "Outdated: the original changed")}
    </.pill>
    """
  end

  def status_badge(%{status: :missing} = assigns) do
    ~H"""
    <.pill tone={:neutral} dot data-testid="translation-status">
      {dgettext("dashboard_languages", "Missing")}
    </.pill>
    """
  end

  def status_badge(assigns), do: ~H""

  # A question's options and texts, and a location's details, name what they
  # belong to, so two "Help text" fields can be told apart.
  defp label(%{kind: kind, context: context}) when is_binary(context) and context != "" do
    dgettext("dashboard_languages", "%{label} (%{context})",
      label: Labels.field_label(kind),
      context: context
    )
  end

  defp label(%{kind: kind}), do: Labels.field_label(kind)

  defp field_id(path), do: String.replace(path, ~r/[^A-Za-z0-9_-]/, "-")
end
