defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm do
  @moduledoc """
  LiveComponent that renders and manages the Meeting Type form UI state.

  It handles local UI events (validate, icon selection, meeting mode toggle,
  provider selection). When editing an existing meeting type, each change
  auto-saves via `MeetingTypeForm.Autosave`; when creating a new one, the
  parent component handles the final "Create" submit/persist event.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  # Follow project rule: ALWAYS alias nested modules and organize alphabetically within groups
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.FormView
  alias Tymeslot.Utils.ReminderUtils
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{Autosave, Init, Validation}

  alias TymeslotWeb.Live.Shared.FormValidationHelpers

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
     |> assign(:no_writable_calendars, false)
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
     |> assign(:allow_guests, false)
     |> assign(:show_as_free, false)
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
  def render(assigns), do: FormView.form(assigns)

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
      |> assign(:no_writable_calendars, false)
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
  def handle_event("toggle_allow_guests", _params, socket) do
    {:noreply,
     socket
     |> assign(:allow_guests, !socket.assigns.allow_guests)
     |> Autosave.maybe_run()}
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_show_as_free", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_as_free, !socket.assigns.show_as_free)
     |> Autosave.maybe_run()}
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
           dgettext("dashboard_meeting_form", "Added %{label} before",
             label: ReminderUtils.format_reminder_label(reminder.value, reminder.unit)
           )
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
             dgettext("dashboard_meeting_form", "Added %{label} before",
               label: ReminderUtils.format_reminder_label(reminder.value, reminder.unit)
             )
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
