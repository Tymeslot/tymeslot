defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm do
  @moduledoc """
  LiveComponent that renders and manages the Meeting Type form UI state.

  It handles local UI events (validate, icon selection, meeting mode toggle,
  provider selection). When editing an existing meeting type, each change
  auto-saves via `MeetingTypeForm.Autosave`; when creating a new one, the
  parent component handles the final "Create" submit/persist event.
  """
  use TymeslotWeb, :live_component

  # Follow project rule: ALWAYS alias nested modules and organize alphabetically within groups
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{
    Autosave,
    CustomQuestionsSection,
    HiddenFields,
    Init,
    PaymentsSection,
    QuestionEditorComponent,
    Validation
  }

  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  import HiddenFields, only: [hidden_fields: 1]
  import PaymentsSection, only: [payments_section: 1]
  import TymeslotWeb.Dashboard.MeetingSettings.Components.BookingComponents
  import TymeslotWeb.Dashboard.MeetingSettings.Components.Reminders

  # Public assigns passed from parent
  # - type: existing meeting type or nil
  # - is_edit: whether we are editing
  # - video_integrations: list for selection
  # - parent_myself: phx-target for parent events (submit/cancel)
  # - saving: parent's saving state to control the button disabled state
  # - current_user: used for security metadata in validation

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form_errors, %{})
     |> assign(:form_data, %{})
     |> assign(:selected_icon, "none")
     |> assign(:meeting_mode, "personal")
     |> assign(:selected_video_integration_id, nil)
     |> assign(:selected_calendar_integration_id, nil)
     |> assign(:selected_target_calendar_id, nil)
     |> assign(:available_calendars, [])
     |> assign(:refreshing_calendars, false)
     |> assign(:reminders, [])
     |> assign(:new_reminder_value, "")
     |> assign(:new_reminder_unit, "minutes")
     |> assign(:reminder_error, nil)
     |> assign(:show_custom_reminder, false)
     |> assign(:reminder_confirmation, nil)
     |> assign(:custom_fields, [])
     |> assign(:save_status, :saved)
     |> assign(:editing_question, nil)
     |> assign(:editing_question_mode, :add)
     |> assign(:custom_questions_allowed, true)
     |> assign(:payments_feature_enabled, false)
     |> assign(:payments_charges_enabled, false)
     |> assign(:payment_currency, "usd")
     |> assign(:payment_currency_minimum_cents, 50)
     |> assign(:payment_required, false)
     |> assign(:payment_price, "")
     |> assign(:__initialized__, false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> Init.maybe_initialize()

    # Custom-question edits arrive here as a `send_update` carrying
    # `:custom_fields` (add/edit/delete/reorder). Persist them like any other
    # change so auto-save covers the question editor too.
    #
    # Deferred autosave retries (throttle backoff) arrive as `trigger_autosave: true`.
    #
    # Other send_updates (calendar refresh, reminder-confirmation clearing) don't
    # carry either key and skip the autosave.
    if Map.has_key?(assigns, :custom_fields) or Map.get(assigns, :trigger_autosave) == true do
      {:ok, Autosave.maybe_run(socket)}
    else
      {:ok, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={"meeting-type-form-wrapper-#{@id}"}>
    <form
      id={"meeting-type-form-#{@id}"}
      phx-submit={if @is_edit, do: "flush_autosave", else: "save_meeting_type"}
      phx-target={if @is_edit, do: @myself, else: @parent_myself}
      class="space-y-4"
    >
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.input
          name="meeting_type[name]"
          label="Name"
          value={Map.get(@form_data, "name", if(@type, do: @type.name, else: ""))}
          required
          maxlength={Constraints.name_length_opts()[:max]}
          placeholder="e.g., Quick Chat"
          phx-change="validate_meeting_type"
          phx-debounce="500"
          phx-target={@myself}
          errors={
            FormValidationHelpers.field_errors(@form_errors, :name)
            |> Enum.map(&Helpers.format_errors/1)
          }
          icon="hero-tag"
        />

        <div>
          <.input
            type="number"
            name="meeting_type[duration]"
            label="Duration (minutes)"
            value={Map.get(@form_data, "duration", if(@type, do: @type.duration_minutes, else: "30"))}
            min={Constraints.duration_minutes_form_min()}
            max={Constraints.duration_minutes_opts()[:less_than_or_equal_to]}
            step="5"
            required
            placeholder="30"
            phx-change="validate_meeting_type"
            phx-debounce="500"
            phx-target={@myself}
            errors={
              FormValidationHelpers.field_errors(@form_errors, :duration)
              |> Enum.map(&Helpers.format_errors/1)
            }
            icon="hero-clock"
          />
          <p class="mt-1 text-token-sm text-tymeslot-600">
            Enter a duration between {Constraints.duration_minutes_form_min()} and {Constraints.duration_minutes_opts()[:less_than_or_equal_to]} minutes
          </p>
        </div>
      </div>

      <.input
        name="meeting_type[description]"
        label="Description (optional)"
        value={Map.get(@form_data, "description", if(@type, do: @type.description, else: ""))}
        maxlength={Constraints.description_max_length()}
        placeholder="Brief description of this meeting type"
        phx-change="validate_meeting_type"
        phx-debounce="500"
        phx-target={@myself}
        errors={
          FormValidationHelpers.field_errors(@form_errors, :description)
          |> Enum.map(&Helpers.format_errors/1)
        }
        icon="hero-document-text"
      />

      <.reminders_section
        reminders={@reminders}
        new_reminder_value={@new_reminder_value}
        new_reminder_unit={@new_reminder_unit}
        reminder_error={@reminder_error}
        show_custom_reminder={@show_custom_reminder}
        reminder_confirmation={@reminder_confirmation}
        form_errors={@form_errors}
        myself={@myself}
      />

      <.icon_picker
        selected_icon={@selected_icon}
        form_errors={@form_errors}
        myself={@myself}
      />

      <.meeting_mode_section
        meeting_mode={@meeting_mode}
        video_integrations={@video_integrations}
        selected_video_integration_id={@selected_video_integration_id}
        form_errors={@form_errors}
        myself={@myself}
      />

      <.booking_destination_section
        calendar_integrations={@calendar_integrations}
        selected_calendar_integration_id={@selected_calendar_integration_id}
        refreshing_calendars={@refreshing_calendars}
        available_calendars={@available_calendars}
        selected_target_calendar_id={@selected_target_calendar_id}
        form_errors={@form_errors}
        myself={@myself}
      />

      <.payments_section
        :if={@payments_feature_enabled}
        charges_enabled={@payments_charges_enabled}
        payment_required={@payment_required}
        payment_price={@payment_price}
        currency={@payment_currency}
        currency_minimum_cents={@payment_currency_minimum_cents}
        form_errors={@form_errors}
        myself={@myself}
      />

      <%!-- Custom questions section --%>
      <.live_component
        module={CustomQuestionsSection}
        id={"custom-questions-section-#{@id}"}
        custom_fields={@custom_fields}
        form_id={@id}
        allowed={@custom_questions_allowed}
        current_user={@current_user}
      />

      <%!-- Create-mode form serialisation. Edits auto-save from socket assigns
           (see Autosave/Submission) and never post the form, so these hidden
           inputs are only needed when creating. --%>
      <.hidden_fields
        :if={!@is_edit}
        type={@type}
        meeting_mode={@meeting_mode}
        selected_icon={@selected_icon}
        selected_video_integration_id={@selected_video_integration_id}
        selected_calendar_integration_id={@selected_calendar_integration_id}
        selected_target_calendar_id={@selected_target_calendar_id}
        reminders={@reminders}
        custom_fields={@custom_fields}
        custom_questions_allowed={@custom_questions_allowed}
        payments_feature_enabled={@payments_feature_enabled}
        payments_charges_enabled={@payments_charges_enabled}
        payment_required={@payment_required}
        payment_price={@payment_price}
      />

      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :base) do %>
        <p class="form-error">{Helpers.format_errors(error)}</p>
      <% end %>

      <div class="flex items-center justify-between gap-4">
        <%= if @is_edit do %>
          <Autosave.indicator status={@save_status} />
          <button
            type="button"
            phx-click="close_edit_overlay"
            phx-target={@parent_myself}
            class="btn btn-primary"
          >
            Done
          </button>
        <% else %>
          <span></span>
          <div class="flex justify-end space-x-3">
            <button
              type="button"
              phx-click="toggle_add_form"
              phx-target={@parent_myself}
              class="btn btn-secondary"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={@saving || @refreshing_calendars}
              class="btn btn-primary"
            >
              <%= if @saving do %>
                <span class="flex items-center">
                  <svg class="animate-spin h-4 w-4 mr-2" fill="none" viewBox="0 0 24 24">
                    <circle
                      class="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      stroke-width="4"
                    >
                    </circle>
                    <path
                      class="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    >
                    </path>
                  </svg>
                  Saving...
                </span>
              <% else %>
                Create Meeting Type
              <% end %>
            </button>
          </div>
        <% end %>
      </div>
    </form>

    <%!-- Question editor modal — rendered outside <form> to avoid nested forms --%>
    <%= if @editing_question do %>
      <.live_component
        module={QuestionEditorComponent}
        id={"question-editor-#{@id}"}
        definition={@editing_question}
        existing_fields={@custom_fields}
        form_id={@id}
        mode={@editing_question_mode}
      />
    <% end %>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("validate_meeting_type", %{"meeting_type" => params}, socket) do
    metadata = Helpers.get_security_metadata(socket)

    # Merge incoming params into existing form data to prevent wiping other fields
    new_data = Map.merge(socket.assigns.form_data || %{}, params)

    # Determine which fields changed (input-level phx-change sends only the targeted field)
    changed_fields = Map.keys(params)

    # Start from existing errors and update only the changed fields
    current_errors = socket.assigns.form_errors || %{}

    {updated_data, updated_errors} =
      Enum.reduce(changed_fields, {new_data, current_errors}, fn field, {acc_data, acc_errors} ->
        Validation.validate_and_update_field(
          field,
          Map.get(params, field),
          metadata,
          acc_data,
          acc_errors
        )
      end)

    {:noreply,
     socket
     |> assign(form_data: updated_data, form_errors: updated_errors)
     |> Autosave.maybe_run()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_meeting_mode", %{"mode" => mode}, socket) do
    socket =
      socket
      |> assign(:meeting_mode, mode)
      |> assign(
        :form_errors,
        FormValidationHelpers.delete_field_error(socket.assigns.form_errors, :video_integration)
      )

    {:noreply, Autosave.maybe_run(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_icon", %{"icon" => icon}, socket) do
    {:noreply, socket |> assign(:selected_icon, icon) |> Autosave.maybe_run()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_video_integration", %{"id" => id}, socket) do
    integration_id =
      case id do
        id when is_binary(id) -> String.to_integer(id)
        id when is_integer(id) -> id
      end

    socket =
      socket
      |> assign(:selected_video_integration_id, integration_id)
      |> assign(
        :form_errors,
        FormValidationHelpers.delete_field_error(socket.assigns.form_errors, :video_integration)
      )

    {:noreply, Autosave.maybe_run(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_calendar_integration", %{"id" => id}, socket) do
    integration_id =
      case id do
        id when is_binary(id) -> String.to_integer(id)
        id when is_integer(id) -> id
      end

    # Send a message to parent to fetch fresh calendars
    send(self(), {:refresh_calendar_list, socket.assigns.id, integration_id})

    socket =
      socket
      |> assign(:selected_calendar_integration_id, integration_id)
      |> assign(:refreshing_calendars, true)
      |> assign(:available_calendars, [])
      |> assign(:selected_target_calendar_id, nil)
      |> assign(
        :form_errors,
        FormValidationHelpers.delete_field_error(
          socket.assigns.form_errors,
          :calendar_integration
        )
      )

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_target_calendar", %{"id" => id}, socket) do
    socket =
      socket
      |> assign(:selected_target_calendar_id, id)
      |> assign(
        :form_errors,
        FormValidationHelpers.delete_field_error(socket.assigns.form_errors, :target_calendar)
      )

    {:noreply, Autosave.maybe_run(socket)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_payment_required", _params, socket) do
    # Guard: hosts who cannot accept charges must not flip the toggle even
    # if a stale/forged event arrives — the control renders disabled.
    if socket.assigns.payments_charges_enabled do
      {:noreply,
       socket
       |> assign(:payment_required, !socket.assigns.payment_required)
       |> assign(
         :form_errors,
         FormValidationHelpers.delete_field_error(socket.assigns.form_errors, :payment_required)
       )
       |> Autosave.maybe_run()}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("change_payment_price", %{"meeting_type" => %{"price_input" => price}}, socket) do
    {:noreply,
     socket
     |> assign(:payment_price, price)
     |> assign(
       :form_errors,
       FormValidationHelpers.delete_field_error(socket.assigns.form_errors, :price_cents)
     )
     |> Autosave.maybe_run()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("update_reminder_input", %{"reminder" => reminder_params}, socket) do
    reminder_value = Map.get(reminder_params, "value", socket.assigns.new_reminder_value)
    reminder_unit = Map.get(reminder_params, "unit", socket.assigns.new_reminder_unit)

    {:noreply,
     assign(socket,
       new_reminder_value: reminder_value,
       new_reminder_unit: reminder_unit,
       reminder_error: nil
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_custom_reminder", _params, socket) do
    {:noreply,
     assign(socket,
       show_custom_reminder: !socket.assigns.show_custom_reminder,
       reminder_confirmation: nil
     )}
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_quick_reminder", params, socket) do
    # Handle map from JS.push
    {amount, unit} =
      case params do
        %{"amount" => a, "unit" => u} -> {a, u}
        _other -> {nil, nil}
      end

    case Validation.validate_new_reminder(socket.assigns.reminders, amount, unit) do
      {:ok, reminder} ->
        reminders = socket.assigns.reminders ++ [reminder]

        # Clear any existing confirmation timer if we had one
        Process.send_after(self(), {:clear_reminder_confirmation, socket.assigns.id}, 3000)

        {:noreply,
         socket
         |> assign(:reminders, reminders)
         |> assign(
           :reminder_confirmation,
           "Added #{ReminderUtils.format_reminder_label(reminder.value, reminder.unit)} before"
         )
         |> assign(:reminder_error, nil)
         |> Autosave.maybe_run()}

      {:error, message} ->
        {:noreply, assign(socket, reminder_error: message)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_reminder", _params, socket) do
    value = socket.assigns.new_reminder_value
    unit = socket.assigns.new_reminder_unit

    case Validation.validate_new_reminder(socket.assigns.reminders, value, unit) do
      {:ok, reminder} ->
        reminders = socket.assigns.reminders ++ [reminder]

        Process.send_after(self(), {:clear_reminder_confirmation, socket.assigns.id}, 3000)

        {:noreply,
         socket
         |> assign(
           reminders: reminders,
           new_reminder_value: "",
           reminder_error: nil,
           show_custom_reminder: false,
           reminder_confirmation:
             "Added #{ReminderUtils.format_reminder_label(reminder.value, reminder.unit)} before"
         )
         |> Autosave.maybe_run()}

      {:error, message} ->
        {:noreply, assign(socket, reminder_error: message)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("remove_reminder", params, socket) do
    # Handle both JS.push map and individual phx-value-params
    {value, unit} =
      case params do
        %{"value" => %{"value" => v, "unit" => u}} -> {v, u}
        %{"value" => v, "unit" => u} -> {v, u}
        _other -> {nil, nil}
      end

    reminders =
      Enum.reject(socket.assigns.reminders, fn reminder ->
        reminder.value == ReminderUtils.parse_reminder_value(value) and reminder.unit == unit
      end)

    {:noreply,
     socket
     |> assign(reminders: reminders, reminder_error: nil)
     |> Autosave.maybe_run()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("flush_autosave", _params, socket) do
    # Edit-mode submit (e.g. pressing Enter) persists current state in place
    # without closing the overlay — there is no separate "save" action.
    {:noreply, Autosave.maybe_run(socket)}
  end
end
