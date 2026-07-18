defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.ReminderHandlers do
  @moduledoc """
  Event-handling logic for the meeting-type form's reminders section.

  Extracted from `MeetingTypeForm` to keep that module under the project's
  line-count limit — `MeetingTypeForm.handle_event/3` delegates the
  `update_reminder_input`, `toggle_custom_reminder`, `add_quick_reminder`,
  `add_reminder`, and `remove_reminder` events here, each taking the socket
  and returning the updated socket (auto-saving where the change is
  persistable).
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.ReminderUtils
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{Autosave, Validation}

  @spec update_reminder_input(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def update_reminder_input(reminder_params, socket) do
    reminder_value = Map.get(reminder_params, "value", socket.assigns.new_reminder_value)
    reminder_unit = Map.get(reminder_params, "unit", socket.assigns.new_reminder_unit)

    assign(socket,
      new_reminder_value: reminder_value,
      new_reminder_unit: reminder_unit,
      reminder_error: nil
    )
  end

  @spec toggle_custom_reminder(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_custom_reminder(socket) do
    assign(socket,
      show_custom_reminder: !socket.assigns.show_custom_reminder,
      reminder_confirmation: nil
    )
  end

  @spec add_quick_reminder(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def add_quick_reminder(params, socket) do
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

        socket
        |> assign(:reminders, reminders)
        |> assign(
          :reminder_confirmation,
          dgettext("dashboard_meeting_form", "Added %{label} before",
            label: ReminderUtils.format_reminder_label(reminder.value, reminder.unit)
          )
        )
        |> assign(:reminder_error, nil)
        |> Autosave.maybe_run()

      {:error, message} ->
        assign(socket, reminder_error: message)
    end
  end

  @spec add_reminder(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def add_reminder(socket) do
    value = socket.assigns.new_reminder_value
    unit = socket.assigns.new_reminder_unit

    case Validation.validate_new_reminder(socket.assigns.reminders, value, unit) do
      {:ok, reminder} ->
        reminders = socket.assigns.reminders ++ [reminder]

        Process.send_after(self(), {:clear_reminder_confirmation, socket.assigns.id}, 3000)

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
        |> Autosave.maybe_run()

      {:error, message} ->
        assign(socket, reminder_error: message)
    end
  end

  @spec remove_reminder(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def remove_reminder(params, socket) do
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

    socket
    |> assign(reminders: reminders, reminder_error: nil)
    |> Autosave.maybe_run()
  end
end
