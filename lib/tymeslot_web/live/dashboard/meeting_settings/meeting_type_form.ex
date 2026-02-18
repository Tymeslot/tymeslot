defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm do
  @moduledoc """
  LiveComponent that renders and manages the Meeting Type form UI state.

  It handles local UI events (validate, icon selection, meeting mode toggle, provider selection)
  while the parent component handles the final submit/persist event.
  """
  use TymeslotWeb, :live_component

  # Follow project rule: ALWAYS alias nested modules and organize alphabetically within groups
  alias Tymeslot.MeetingTypes.InputValidation, as: MeetingSettingsInputValidation
  alias Tymeslot.Utils.ReminderUtils
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  import TymeslotWeb.Dashboard.MeetingSettings.Components

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
     |> assign(:__initialized__, false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, maybe_initialize(socket)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <form phx-submit="save_meeting_type" phx-target={@parent_myself} class="space-y-4">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <.input
          name="meeting_type[name]"
          label="Name"
          value={Map.get(@form_data, "name", if(@type, do: @type.name, else: ""))}
          required
          maxlength="100"
          placeholder="e.g., Quick Chat"
          phx-change="validate_meeting_type"
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
            min="5"
            max="480"
            step="5"
            required
            placeholder="30"
            phx-change="validate_meeting_type"
            phx-target={@myself}
            errors={
              FormValidationHelpers.field_errors(@form_errors, :duration)
              |> Enum.map(&Helpers.format_errors/1)
            }
            icon="hero-clock"
          />
          <p class="mt-1 text-token-sm text-tymeslot-600">
            Enter a duration between 5 and 480 minutes
          </p>
        </div>
      </div>

      <.input
        name="meeting_type[description]"
        label="Description (optional)"
        value={Map.get(@form_data, "description", if(@type, do: @type.description, else: ""))}
        maxlength="500"
        placeholder="Brief description of this meeting type"
        phx-change="validate_meeting_type"
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

      <!-- Hidden fields -->
      <%= for reminder <- @reminders do %>
        <input type="hidden" name="meeting_type[reminder_config][][value]" value={reminder.value} />
        <input type="hidden" name="meeting_type[reminder_config][][unit]" value={reminder.unit} />
      <% end %>
      <input
        type="hidden"
        name="meeting_type[is_active]"
        value={if @type, do: to_string(@type.is_active), else: "true"}
      />
      <input type="hidden" name="meeting_type[meeting_mode]" value={@meeting_mode} />
      <input
        type="hidden"
        name="meeting_type[video_integration_id]"
        value={@selected_video_integration_id}
      />
      <input
        type="hidden"
        name="meeting_type[calendar_integration_id]"
        value={@selected_calendar_integration_id}
      />
      <input
        type="hidden"
        name="meeting_type[target_calendar_id]"
        value={@selected_target_calendar_id}
      />
      <input type="hidden" name="meeting_type[icon]" value={@selected_icon} />

      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :base) do %>
        <p class="form-error">{Helpers.format_errors(error)}</p>
      <% end %>

      <div class="flex justify-end space-x-3">
        <button
          type="button"
          phx-click={if @is_edit, do: "close_edit_overlay", else: "toggle_add_form"}
          phx-target={@parent_myself}
          class="btn btn-secondary"
        >
          Cancel
        </button>
        <button type="submit" disabled={@saving || @refreshing_calendars} class="btn btn-primary">
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
            {if @is_edit, do: "Update", else: "Create"} Meeting Type
          <% end %>
        </button>
      </div>
    </form>
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
        validate_and_update_field(field, Map.get(params, field), metadata, acc_data, acc_errors)
      end)

    {:noreply, assign(socket, form_data: updated_data, form_errors: updated_errors)}
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

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("select_icon", %{"icon" => icon}, socket) do
    {:noreply, assign(socket, :selected_icon, icon)}
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

    {:noreply, socket}
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

    {:noreply, socket}
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

    case validate_new_reminder(socket.assigns.reminders, amount, unit) do
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
         |> assign(:reminder_error, nil)}

      {:error, message} ->
        {:noreply, assign(socket, reminder_error: message)}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("add_reminder", _params, socket) do
    value = socket.assigns.new_reminder_value
    unit = socket.assigns.new_reminder_unit

    case validate_new_reminder(socket.assigns.reminders, value, unit) do
      {:ok, reminder} ->
        reminders = socket.assigns.reminders ++ [reminder]

        Process.send_after(self(), {:clear_reminder_confirmation, socket.assigns.id}, 3000)

        {:noreply,
         assign(socket,
           reminders: reminders,
           new_reminder_value: "",
           reminder_error: nil,
           show_custom_reminder: false,
           reminder_confirmation:
             "Added #{ReminderUtils.format_reminder_label(reminder.value, reminder.unit)} before"
         )}

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

    {:noreply, assign(socket, reminders: reminders, reminder_error: nil)}
  end

  # --- Private helpers ---
  defp validate_and_update_field("name", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_meeting_type_field(:name, value,
           metadata: metadata
         ) do
      {:ok, sanitized} -> {Map.put(acc_data, "name", sanitized), Map.delete(acc_errors, :name)}
      {:error, %{name: msg}} -> {acc_data, Map.put(acc_errors, :name, msg)}
      {:error, _reason} -> {acc_data, acc_errors}
    end
  end

  defp validate_and_update_field("duration", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_meeting_type_field(:duration, value,
           metadata: metadata
         ) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "duration", sanitized), Map.delete(acc_errors, :duration)}

      {:error, %{duration: msg}} ->
        {acc_data, Map.put(acc_errors, :duration, msg)}

      {:error, _reason} ->
        {acc_data, acc_errors}
    end
  end

  defp validate_and_update_field("description", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_meeting_type_field(:description, value,
           metadata: metadata
         ) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "description", sanitized), Map.delete(acc_errors, :description)}

      {:error, %{description: msg}} ->
        {acc_data, Map.put(acc_errors, :description, msg)}

      {:error, _reason} ->
        {acc_data, acc_errors}
    end
  end

  defp validate_and_update_field(_other, _value, _metadata, acc_data, acc_errors),
    do: {acc_data, acc_errors}

  defp maybe_initialize(%{assigns: %{__initialized__: true}} = socket), do: socket

  defp maybe_initialize(%{assigns: assigns} = socket) do
    type = Map.get(assigns, :type)

    socket
    |> assign(:selected_icon, get_selected_icon(type))
    |> assign(:meeting_mode, get_meeting_mode(type))
    |> assign(:selected_video_integration_id, get_video_integration_id(type))
    |> assign(:selected_calendar_integration_id, get_calendar_integration_id(type))
    |> assign(:selected_target_calendar_id, get_target_calendar_id(type))
    |> assign(:reminders, get_reminders(type))
    |> then(fn socket ->
      if id = socket.assigns.selected_calendar_integration_id do
        assign(
          socket,
          :available_calendars,
          fetch_available_calendars(id, socket.assigns.calendar_integrations)
        )
      else
        socket
      end
    end)
    |> assign(:form_data, build_form_data(type))
    |> assign(:__initialized__, true)
  end

  defp get_selected_icon(nil), do: "none"
  defp get_selected_icon(%{icon: icon}) when is_binary(icon) and icon != "", do: icon
  defp get_selected_icon(_arg), do: "none"

  defp get_meeting_mode(%{allow_video: true}), do: "video"
  defp get_meeting_mode(_arg), do: "personal"

  defp get_video_integration_id(nil), do: nil
  defp get_video_integration_id(%{video_integration_id: nil}), do: nil
  defp get_video_integration_id(%{video_integration_id: id}) when is_integer(id), do: id

  defp get_video_integration_id(%{video_integration_id: id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, _value} -> int
      :error -> nil
    end
  end

  defp get_video_integration_id(_arg), do: nil

  defp get_calendar_integration_id(nil), do: nil
  defp get_calendar_integration_id(%{calendar_integration_id: nil}), do: nil
  defp get_calendar_integration_id(%{calendar_integration_id: id}), do: id

  defp get_target_calendar_id(nil), do: nil
  defp get_target_calendar_id(%{target_calendar_id: nil}), do: nil
  defp get_target_calendar_id(%{target_calendar_id: id}), do: id

  defp fetch_available_calendars(integration_id, integrations) do
    integration = Enum.find(integrations, &(&1.id == integration_id))

    if integration && integration.calendar_list do
      integration.calendar_list
    else
      []
    end
  end

  defp build_form_data(nil) do
    %{"name" => "", "duration" => "30", "description" => "", "icon" => "none"}
  end

  defp build_form_data(type) do
    %{
      "name" => type.name || "",
      "duration" => to_string(type.duration_minutes || 30),
      "description" => type.description || "",
      "icon" => type.icon || "none"
    }
  end

  defp get_reminders(nil), do: [%{value: 30, unit: "minutes"}]

  defp get_reminders(%{reminder_config: reminders}) when is_list(reminders) do
    Enum.flat_map(reminders, fn r ->
      case ReminderUtils.normalize_reminder(r) do
        {:ok, reminder} -> [reminder]
        _other -> []
      end
    end)
  end

  defp get_reminders(_arg), do: [%{value: 30, unit: "minutes"}]

  defp validate_new_reminder(reminders, value, unit) do
    cond do
      is_nil(value) or value == "" ->
        {:error, "Reminder value is required"}

      length(reminders) >= 3 ->
        {:error, "You can configure up to 3 reminders"}

      match?({:error, _reason}, ReminderUtils.validate_reminder_value(value)) ->
        {:error, "Reminder value must be a positive number"}

      unit not in ["minutes", "hours", "days"] ->
        {:error, "Select a valid reminder unit"}

      reminder_exists?(reminders, value, unit) ->
        {:error, "This reminder already exists"}

      true ->
        {:ok, %{value: ReminderUtils.parse_reminder_value(value), unit: unit}}
    end
  end

  defp reminder_exists?(reminders, value, unit) do
    reminder_value = ReminderUtils.parse_reminder_value(value)
    new_reminder = %{value: reminder_value, unit: unit}

    ReminderUtils.duplicate_reminders?(reminders ++ [new_reminder])
  end
end
