defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Validation do
  @moduledoc "Field-level validation helpers for MeetingTypeForm."

  alias Tymeslot.MeetingTypes.InputValidation, as: MeetingSettingsInputValidation

  @doc "Validates a single named field and returns the updated `{data, errors}` tuple."
  @spec validate_and_update_field(String.t(), any(), map(), map(), map()) :: {map(), map()}
  def validate_and_update_field("name", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputValidation.validate_field(:name, value, metadata) do
      {:ok, sanitized} -> {Map.put(acc_data, "name", sanitized), Map.delete(acc_errors, :name)}
      {:error, %{name: msg}} -> {acc_data, Map.put(acc_errors, :name, msg)}
    end
  end

  def validate_and_update_field("duration", value, metadata, acc_data, acc_errors) do
    {data, errors} =
      case MeetingSettingsInputValidation.validate_field(:duration, value, metadata) do
        {:ok, sanitized} ->
          {Map.put(acc_data, "duration", sanitized), Map.delete(acc_errors, :duration)}

        {:error, %{duration: msg}} ->
          {acc_data, Map.put(acc_errors, :duration, msg)}
      end

    # A new primary duration can collide with, or stop colliding with, one of
    # the further durations.
    revalidate_extra_lengths(data, errors, metadata)
  end

  def validate_and_update_field("extra_lengths", value, metadata, acc_data, acc_errors) do
    data =
      Map.put(
        acc_data,
        "extra_lengths",
        MeetingSettingsInputValidation.extra_lengths_list(value)
      )

    revalidate_extra_lengths(data, acc_errors, metadata)
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
  Checks the further durations in `data` against the primary one and updates
  the `:extra_lengths` error.
  """
  @spec revalidate_extra_lengths(map(), map(), map()) :: {map(), map()}
  def revalidate_extra_lengths(data, errors, metadata) do
    value = {Map.get(data, "extra_lengths", []), Map.get(data, "duration")}

    case MeetingSettingsInputValidation.validate_field(:extra_lengths, value, metadata) do
      {:ok, _sanitized} -> {data, Map.delete(errors, :extra_lengths)}
      {:error, %{extra_lengths: msg}} -> {data, Map.put(errors, :extra_lengths, msg)}
    end
  end
end
