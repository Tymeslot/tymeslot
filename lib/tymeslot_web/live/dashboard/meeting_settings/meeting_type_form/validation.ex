defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Validation do
  @moduledoc "Field-level and reminder validation helpers for MeetingTypeForm."

  alias Tymeslot.MeetingTypes.InputValidation, as: MeetingSettingsInputValidation
  alias Tymeslot.Utils.ReminderUtils

  @doc "Validates a single named field and returns the updated `{data, errors}` tuple."
  @spec validate_and_update_field(String.t(), any(), map(), map(), map()) :: {map(), map()}
  def validate_and_update_field("name", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:name, value, metadata) do
      {:ok, sanitized} -> {Map.put(acc_data, "name", sanitized), Map.delete(acc_errors, :name)}
      {:error, %{name: msg}} -> {acc_data, Map.put(acc_errors, :name, msg)}
      {:error, _reason} -> {acc_data, acc_errors}
    end
  end

  def validate_and_update_field("duration", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:duration, value, metadata) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "duration", sanitized), Map.delete(acc_errors, :duration)}

      {:error, %{duration: msg}} ->
        {acc_data, Map.put(acc_errors, :duration, msg)}

      {:error, _reason} ->
        {acc_data, acc_errors}
    end
  end

  def validate_and_update_field("description", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:description, value, metadata) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "description", sanitized), Map.delete(acc_errors, :description)}

      {:error, %{description: msg}} ->
        {acc_data, Map.put(acc_errors, :description, msg)}

      {:error, _reason} ->
        {acc_data, acc_errors}
    end
  end

  def validate_and_update_field(_other, _value, _metadata, acc_data, acc_errors),
    do: {acc_data, acc_errors}

  @doc "Validates a new reminder and returns `{:ok, reminder}` or `{:error, message}`."
  @spec validate_new_reminder(list(), any(), any()) :: {:ok, map()} | {:error, String.t()}
  def validate_new_reminder(reminders, value, unit) do
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

  # --- Private helpers ---

  defp reminder_exists?(reminders, value, unit) do
    reminder_value = ReminderUtils.parse_reminder_value(value)
    new_reminder = %{value: reminder_value, unit: unit}

    ReminderUtils.duplicate_reminders?(reminders ++ [new_reminder])
  end
end
