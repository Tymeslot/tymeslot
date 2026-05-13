defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.QuestionEditorComponent do
  @moduledoc """
  Modal editor for a single `FieldDefinition`. Owns a private Ecto changeset
  over the definition being created or updated.

  Emits `{:custom_questions, :save, definition}` to the parent LiveView on a
  valid save, or `{:custom_questions, :cancel}` when the host dismisses the
  editor without saving.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Phoenix.Component
  alias Phoenix.LiveView.JS
  alias Tymeslot.CustomFields.FieldDefinition
  alias TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    definition = assigns[:definition] || %FieldDefinition{}
    changeset = FieldDefinition.changeset(definition, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:definition, definition)
     |> assign(:changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"definition" => params}, socket) do
    params = normalise_params(params)

    changeset =
      socket.assigns.definition
      |> FieldDefinition.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"definition" => params}, socket) do
    params = normalise_params(params)
    changeset = FieldDefinition.changeset(socket.assigns.definition, params)

    if changeset.valid? do
      definition = Changeset.apply_changes(changeset)
      existing = socket.assigns.existing_fields || []

      updated =
        if Enum.any?(existing, &(&1.id == definition.id)) do
          Enum.map(existing, fn d -> if d.id == definition.id, do: definition, else: d end)
        else
          existing ++ [definition]
        end

      send(self(), {:custom_questions, :fields_updated, updated, socket.assigns.form_id})
      {:noreply, socket}
    else
      {:noreply, assign(socket, :changeset, Map.put(changeset, :action, :insert))}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel", _params, socket) do
    send(self(), {:custom_questions, :cancel, socket.assigns.form_id})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns, :form, Component.to_form(assigns.changeset, as: :definition))

    ~H"""
    <div id={"question-editor-wrapper-#{@id}"}>
      <CoreComponents.modal
        id={"question-editor-#{@id}"}
        show
        on_cancel={JS.push("cancel", target: @myself)}
        size={:medium}
      >
        <:header>
          <%= if @definition.id do %>
            {gettext("Edit question")}
          <% else %>
            {gettext("Add question")}
          <% end %>
        </:header>

        <.form
          for={@form}
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          class="space-y-4"
        >
          <CoreComponents.input
            field={@form[:label]}
            type="text"
            label={gettext("Label")}
            placeholder={gettext("e.g., Company name")}
            required
          />

          <CoreComponents.input
            field={@form[:help_text]}
            type="text"
            label={gettext("Help text (optional)")}
            placeholder={gettext("e.g., Enter your company's registered name")}
          />

          <CoreComponents.input
            field={@form[:type]}
            type="select"
            label={gettext("Type")}
            options={type_options()}
          />

          <CoreComponents.input
            field={@form[:required]}
            type="checkbox"
            label={gettext("Required")}
          />

          <%!-- Type-specific config --%>
          <%= case Ecto.Changeset.get_field(@changeset, :type) do %>
            <% t when t in ["single_select", "multi_select"] -> %>
              <.options_editor changeset={@changeset} myself={@myself} />
            <% "note" -> %>
              <CoreComponents.input
                field={@form[:body]}
                type="textarea"
                label={gettext("Body text")}
                placeholder={gettext("Text that the booker must acknowledge before proceeding")}
                rows={4}
                required
              />
            <% t when t in ~w(number date) -> %>
              <div class="grid grid-cols-2 gap-3">
                <CoreComponents.input
                  field={@form[:min]}
                  type="number"
                  label={gettext("Min")}
                />
                <CoreComponents.input
                  field={@form[:max]}
                  type="number"
                  label={gettext("Max")}
                />
              </div>
            <% _ -> %>
              <%!-- No type-specific fields for short_text, yes_no, phone, url, time --%>
          <% end %>

          <div class="flex justify-end gap-2 pt-2">
            <CoreComponents.action_button
              type="button"
              variant={:secondary}
              phx-click="cancel"
              phx-target={@myself}
            >
              {gettext("Cancel")}
            </CoreComponents.action_button>
            <CoreComponents.action_button type="submit" variant={:primary}>
              {gettext("Save question")}
            </CoreComponents.action_button>
          </div>
        </.form>
      </CoreComponents.modal>
    </div>
    """
  end

  # Private components

  attr :changeset, :any, required: true
  attr :myself, :any, required: true

  defp options_editor(assigns) do
    ~H"""
    <div>
      <label class="label">
        {gettext("Options")}
        <span class="text-red-500 ml-0.5">*</span>
      </label>
      <p class="text-token-sm text-tymeslot-500 mb-2">
        {gettext("Enter one option per line. Keys are generated automatically.")}
      </p>
      <textarea
        name="definition[options_text]"
        rows="5"
        class="input w-full"
        phx-debounce="blur"
      >{options_text(@changeset)}</textarea>
      <%= if @changeset.action do %>
        <%= for {_field, {msg, _opts}} <- Enum.filter(@changeset.errors, fn {k, _} -> k == :options end) do %>
          <p class="field-error">{msg}</p>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Converts a persisted/staged list of FieldOption structs or maps back into
  # the newline-delimited text representation for the textarea.
  defp options_text(changeset) do
    case Changeset.get_field(changeset, :options) do
      opts when is_list(opts) ->
        opts
        |> Enum.map(fn
          %{label: l} -> l
          %{"label" => l} -> l
          _other -> ""
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      _none ->
        ""
    end
  end

  # Transforms `options_text` (newline-delimited string from the textarea) into
  # the `options` list that `FieldDefinition.changeset/2` expects, then removes
  # the raw textarea param. Key derivation is handled server-side by
  # `FieldOption.changeset/2`.
  defp normalise_params(%{"options_text" => text} = params) when is_binary(text) do
    options =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&%{"label" => &1})

    params
    |> Map.put("options", options)
    |> Map.delete("options_text")
  end

  defp normalise_params(params), do: params

  defp type_options do
    [
      {gettext("Short text"), "short_text"},
      {gettext("Number"), "number"},
      {gettext("Single choice"), "single_select"},
      {gettext("Multiple choice"), "multi_select"},
      {gettext("Yes / No"), "yes_no"},
      {gettext("Phone"), "phone"},
      {gettext("URL"), "url"},
      {gettext("Date"), "date"},
      {gettext("Time"), "time"},
      {gettext("Note for acknowledgement"), "note"}
    ]
  end
end
