defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.QuestionEditorComponent do
  @moduledoc """
  Modal editor for a single `FieldDefinition`. Owns a private Ecto changeset
  over the definition being created or updated.

  On a valid save, the component merges the updated definition into the
  existing `custom_fields` list and pushes both `custom_fields` and
  `editing_question: nil` directly into the parent `MeetingTypeForm` via
  `Phoenix.LiveView.send_update/2`. On cancel, it pushes only
  `editing_question: nil` to close the modal. This single-hop approach keeps
  `LiveViewTest` helpers like `render_click/1` deterministic.

  The `mode` assign (`:add` or `:edit`) controls the modal header. It is set
  by `CustomQuestionsSection` and forwarded through `MeetingTypeForm` —
  do not derive it from `@definition.id`, which is always populated.
  """
  use TymeslotWeb, :live_component

  alias Ecto.Changeset
  alias Phoenix.LiveView
  alias Phoenix.LiveView.JS
  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.CustomFields.FieldOption
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @allowed_error_fields ~w(label help_text body options min max)

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    definition = assigns[:definition] || %FieldDefinition{}
    changeset = FieldDefinition.changeset(definition, %{})

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:definition, definition)
     |> assign(:changeset, changeset)
     |> assign_new(:mode, fn -> :add end)
     |> assign_new(:pending_type_change, fn -> nil end)
     |> assign_new(:field_errors, fn -> %{} end)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate", %{"definition" => params} = event_params, socket) do
    new_type = params["type"]
    current_type = Changeset.get_field(socket.assigns.changeset, :type)

    if destructive_type_change?(new_type, current_type, socket.assigns.changeset) do
      {:noreply, assign(socket, :pending_type_change, new_type)}
    else
      changeset = FieldDefinition.changeset(socket.assigns.definition, params)

      field_errors =
        FormValidationHelpers.clear_target_error(
          socket.assigns.field_errors,
          event_params["_target"],
          @allowed_error_fields
        )

      {:noreply,
       socket
       |> assign(:changeset, changeset)
       |> assign(:field_errors, field_errors)
       |> assign(:pending_type_change, nil)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel_type_change", _params, socket) do
    {:noreply, assign(socket, :pending_type_change, nil)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("confirm_type_change", _params, socket) do
    new_type = socket.assigns.pending_type_change
    definition = socket.assigns.definition

    changeset = FieldDefinition.changeset(definition, %{"type" => new_type})

    {:noreply,
     socket
     |> assign(:changeset, changeset)
     |> assign(:pending_type_change, nil)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"definition" => params}, socket) do
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

      LiveView.send_update(MeetingTypeForm,
        id: socket.assigns.form_id,
        custom_fields: updated,
        editing_question: nil
      )

      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:changeset, changeset)
       |> assign(:field_errors, FormValidationHelpers.changeset_errors_map(changeset))}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("cancel", _params, socket) do
    LiveView.send_update(MeetingTypeForm,
      id: socket.assigns.form_id,
      editing_question: nil
    )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("field_blur", %{"field" => field}, socket)
      when field in @allowed_error_fields do
    field_atom = String.to_existing_atom(field)

    field_errors =
      FormValidationHelpers.sync_changeset_field_error(
        socket.assigns.field_errors,
        socket.assigns.changeset,
        field_atom
      )

    {:noreply, assign(socket, :field_errors, field_errors)}
  end

  def handle_event("field_blur", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveComponent
  def handle_event("add_option", _params, socket) do
    options = Changeset.get_field(socket.assigns.changeset, :options) || []

    changeset =
      Changeset.put_embed(socket.assigns.changeset, :options, options ++ [%FieldOption{}])

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("remove_option", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    options = Changeset.get_field(socket.assigns.changeset, :options) || []

    changeset =
      Changeset.put_embed(socket.assigns.changeset, :options, List.delete_at(options, index))

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"question-editor-wrapper-#{@id}"}>
      <CoreComponents.modal
        id={"question-editor-#{@id}"}
        show
        on_cancel={JS.push("cancel", target: @myself)}
        size={:medium}
      >
        <:header>
          <%= if @mode == :edit do %>
            Edit question
          <% else %>
            Add question
          <% end %>
        </:header>

        <.form
          for={@changeset}
          as={:definition}
          id="custom-question-editor-form"
          phx-change="validate"
          phx-submit="save"
          phx-target={@myself}
          class="space-y-4"
        >
          <CoreComponents.input
            name="definition[label]"
            value={field_value(@changeset, :label)}
            id="definition_label"
            type="text"
            label="Label"
            placeholder="e.g., Company name"
            required
            phx-blur="field_blur"
            phx-value-field="label"
            phx-target={@myself}
            errors={FormValidationHelpers.field_errors(@field_errors, :label)}
          >
            <:description>The question shown to the booker.</:description>
          </CoreComponents.input>

          <CoreComponents.input
            name="definition[help_text]"
            value={field_value(@changeset, :help_text)}
            id="definition_help_text"
            type="text"
            label="Help text (optional)"
            placeholder="e.g., Enter your company's registered name"
            phx-blur="field_blur"
            phx-value-field="help_text"
            phx-target={@myself}
            errors={FormValidationHelpers.field_errors(@field_errors, :help_text)}
          >
            <:description>Shown below the question — use it to clarify what you're asking or give an example.</:description>
          </CoreComponents.input>

          <CoreComponents.input
            name="definition[type]"
            value={field_value(@changeset, :type)}
            id="definition_type"
            type="select"
            label="Type"
            options={type_options()}
          >
            <:description>Controls how the booker enters their answer.</:description>
          </CoreComponents.input>

          <CoreComponents.input
            name="definition[required]"
            value={field_value(@changeset, :required)}
            id="definition_required"
            type="checkbox"
            label="Required"
          >
            <:description>The booker must answer this question before they can continue.</:description>
          </CoreComponents.input>

          <%!-- Type-specific config --%>
          <%= case Ecto.Changeset.get_field(@changeset, :type) do %>
            <% t when t in ["single_select", "multi_select"] -> %>
              <.options_editor
                changeset={@changeset}
                field_errors={@field_errors}
                myself={@myself}
              />
            <% "note" -> %>
              <CoreComponents.input
                name="definition[body]"
                value={field_value(@changeset, :body)}
                id="definition_body"
                type="textarea"
                label="Body text"
                placeholder="Text that the booker must acknowledge before proceeding"
                rows={4}
                required
                phx-blur="field_blur"
                phx-value-field="body"
                phx-target={@myself}
                errors={FormValidationHelpers.field_errors(@field_errors, :body)}
              >
                <:description>The notice the booker must read and confirm before they can continue.</:description>
              </CoreComponents.input>
            <% t when t in ~w(number date time) -> %>
              <div class="grid grid-cols-2 gap-3">
                <CoreComponents.input
                  name="definition[min]"
                  value={field_value(@changeset, :min)}
                  id="definition_min"
                  type={bound_input_type(t)}
                  label="Min"
                  errors={FormValidationHelpers.field_errors(@field_errors, :min)}
                >
                  <:description>{bound_min_hint(t)}</:description>
                </CoreComponents.input>
                <CoreComponents.input
                  name="definition[max]"
                  value={field_value(@changeset, :max)}
                  id="definition_max"
                  type={bound_input_type(t)}
                  label="Max"
                  errors={FormValidationHelpers.field_errors(@field_errors, :max)}
                >
                  <:description>{bound_max_hint(t)}</:description>
                </CoreComponents.input>
              </div>
            <% _ -> %>
              <%!-- No type-specific fields for short_text, yes_no, phone, url --%>
          <% end %>

          <%= if @pending_type_change do %>
            <div role="alertdialog" aria-live="polite" class="rounded-token-lg border-2 bg-amber-50 border-amber-200 text-amber-800 p-4">
              <p class="font-medium text-token-sm mb-3">
                Changing the type will clear the configuration you've defined (options, body, min/max). Past bookings keep their original answers. Continue?
              </p>
              <div class="flex gap-2">
                <CoreComponents.action_button
                  type="button"
                  variant={:secondary}
                  phx-click="cancel_type_change"
                  phx-target={@myself}
                >
                  Cancel
                </CoreComponents.action_button>
                <CoreComponents.action_button
                  type="button"
                  variant={:primary}
                  phx-click="confirm_type_change"
                  phx-target={@myself}
                >
                  Yes, change type
                </CoreComponents.action_button>
              </div>
            </div>
          <% end %>

          <div class="flex justify-end gap-2 pt-2">
            <CoreComponents.action_button
              type="button"
              variant={:secondary}
              phx-click="cancel"
              phx-target={@myself}
            >
              Cancel
            </CoreComponents.action_button>
            <CoreComponents.action_button type="submit" variant={:primary}>
              Save question
            </CoreComponents.action_button>
          </div>
        </.form>
      </CoreComponents.modal>
    </div>
    """
  end

  # Private components

  attr :changeset, :any, required: true
  attr :field_errors, :map, required: true
  attr :myself, :any, required: true

  defp options_editor(assigns) do
    ~H"""
    <div>
      <label class="label">
        Options <span class="text-red-500 ml-0.5">*</span>
      </label>
      <p class="text-token-xs text-tymeslot-500 font-medium normal-case tracking-normal -mt-1 mb-3">
        Each entry becomes a selectable choice for the booker.
      </p>
      <div class="space-y-2">
        <%= for {option, index} <- Enum.with_index(options_list(@changeset)) do %>
          <div class="flex items-center gap-2">
            <input
              type="hidden"
              name={"definition[options][#{index}][key]"}
              value={option.key || ""}
            />
            <input
              type="text"
              name={"definition[options][#{index}][label]"}
              value={option.label || ""}
              class="input flex-1"
              placeholder={"Option #{index + 1}"}
              phx-blur="field_blur"
              phx-value-field="options"
              phx-target={@myself}
            />
            <button
              type="button"
              class="flex-shrink-0 p-1 rounded text-tymeslot-400 hover:text-red-500 hover:bg-red-50 transition-colors"
              phx-click="remove_option"
              phx-value-index={index}
              phx-target={@myself}
              aria-label="Remove option"
            >×</button>
          </div>
        <% end %>
      </div>
      <button
        type="button"
        class="mt-2 flex items-center gap-1.5 text-token-sm font-medium text-tymeslot-600 hover:text-tymeslot-900"
        phx-click="add_option"
        phx-target={@myself}
      >
        + Add option
      </button>
      <%= for error <- FormValidationHelpers.field_errors(@field_errors, :options) do %>
        <p class="field-error">{translate_options_error(error)}</p>
      <% end %>
    </div>
    """
  end

  defp translate_options_error({msg, _opts}), do: msg
  defp translate_options_error(msg) when is_binary(msg), do: msg

  defp field_value(changeset, field) do
    Changeset.get_field(changeset, field)
  end

  # Returns true when the newly-selected type differs from the type currently
  # held in the changeset AND that changeset has non-empty type-specific config
  # that would be silently cleared. Comparing against the changeset's own type
  # (rather than a separately-tracked assign) keeps the two in lock-step, so
  # merely editing config for a freshly-chosen type never trips the dialog.
  defp destructive_type_change?(new_type, current_type, changeset)
       when is_binary(new_type) and is_binary(current_type) and new_type != current_type do
    options = Changeset.get_field(changeset, :options)
    has_options = is_list(options) and options != []
    body = Changeset.get_field(changeset, :body)
    has_body = is_binary(body) and body != ""
    has_min = not is_nil(Changeset.get_field(changeset, :min))
    has_max = not is_nil(Changeset.get_field(changeset, :max))
    has_options or has_body or has_min or has_max
  end

  defp destructive_type_change?(_new_type, _current_type, _changeset), do: false

  defp options_list(changeset) do
    Changeset.get_field(changeset, :options) || []
  end

  # The min/max inputs must match the question type so the browser renders a
  # native numeric/date/time picker and the stored bound is a value the
  # matching validator can parse.
  defp bound_input_type("number"), do: "number"
  defp bound_input_type("date"), do: "date"
  defp bound_input_type("time"), do: "time"

  defp bound_min_hint("number"), do: "Lowest value the booker may enter."
  defp bound_min_hint("date"), do: "Earliest date the booker may choose."
  defp bound_min_hint("time"), do: "Earliest time the booker may choose."

  defp bound_max_hint("number"), do: "Highest value the booker may enter."
  defp bound_max_hint("date"), do: "Latest date the booker may choose."
  defp bound_max_hint("time"), do: "Latest time the booker may choose."

  defp type_options do
    [
      {"Short text", "short_text"},
      {"Number", "number"},
      {"Single choice", "single_select"},
      {"Multiple choice", "multi_select"},
      {"Yes / No", "yes_no"},
      {"Phone", "phone"},
      {"URL", "url"},
      {"Date", "date"},
      {"Time", "time"},
      {"Note for acknowledgement", "note"}
    ]
  end
end
