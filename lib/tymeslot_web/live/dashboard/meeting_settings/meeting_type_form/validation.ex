defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Validation do
  @moduledoc "Field-level and reminder validation helpers for MeetingTypeForm."

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.InputValidation, as: MeetingSettingsInputValidation
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Utils.ReminderUtils

  @doc "Validates a single named field and returns the updated `{data, errors}` tuple."
  @spec validate_and_update_field(String.t(), any(), map(), map(), map()) :: {map(), map()}
  def validate_and_update_field("name", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:name, value, metadata) do
      {:ok, sanitized} -> {Map.put(acc_data, "name", sanitized), Map.delete(acc_errors, :name)}
      {:error, %{name: msg}} -> {acc_data, Map.put(acc_errors, :name, msg)}
    end
  end

  def validate_and_update_field("duration", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:duration, value, metadata) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "duration", sanitized), Map.delete(acc_errors, :duration)}

      {:error, %{duration: msg}} ->
        {acc_data, Map.put(acc_errors, :duration, msg)}
    end
  end

  def validate_and_update_field("slot_interval", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:slot_interval, value, metadata) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "slot_interval", sanitized), Map.delete(acc_errors, :slot_interval)}

      {:error, %{slot_interval: msg}} ->
        {acc_data, Map.put(acc_errors, :slot_interval, msg)}
    end
  end

  def validate_and_update_field("description", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:description, value, metadata) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "description", sanitized), Map.delete(acc_errors, :description)}

      {:error, %{description: msg}} ->
        {acc_data, Map.put(acc_errors, :description, msg)}
    end
  end

  def validate_and_update_field(_other, _value, _metadata, acc_data, acc_errors),
    do: {acc_data, acc_errors}

  @doc """
  Validates a reminder about to be added to `reminders` and returns
  `{:ok, reminder}` or `{:error, message}`.

  The input checks are this form's own; whether the resulting list is allowed
  is `ReminderValidation.check_policy/2`, the same rule the save path applies,
  so a reminder accepted here cannot later block the meeting type from saving.
  The reminders already in the list are passed as held, so the year limit
  judges the one being added and not a longer one saved before the limit.
  """
  @spec validate_new_reminder(list(), any(), any()) :: {:ok, map()} | {:error, String.t()}
  def validate_new_reminder(reminders, value, unit) do
    cond do
      is_nil(value) or value == "" ->
        {:error, dgettext("dashboard_meeting_form", "Reminder value is required")}

      match?({:error, _reason}, ReminderUtils.validate_reminder_value(value)) ->
        {:error, dgettext("dashboard_meeting_form", "Reminder value must be a positive number")}

      unit not in ["minutes", "hours", "days"] ->
        {:error, dgettext("dashboard_meeting_form", "Select a valid reminder unit")}

      true ->
        reminder = %{value: ReminderUtils.parse_reminder_value(value), unit: unit}

        case ReminderValidation.check_policy(reminders ++ [reminder], reminders) do
          :ok -> {:ok, reminder}
          {:error, reason} -> {:error, policy_message(reason)}
        end
    end
  end

  # --- Private helpers ---

  defp policy_message(:too_many),
    do: dgettext("dashboard_meeting_form", "You can configure up to 3 reminders")

  defp policy_message(:duplicate),
    do: dgettext("dashboard_meeting_form", "This reminder already exists")

  defp policy_message(:exceeds_max),
    do:
      dgettext(
        "dashboard_meeting_form",
        "Reminders cannot be set for more than 1 year in advance"
      )
end
