defmodule Tymeslot.MeetingTypes.ReminderValidation do
  @moduledoc """
  Validation and normalisation for meeting type reminder configuration.

  Handles parsing, normalisation, and policy enforcement for reminder
  settings attached to meeting types.
  """

  alias Tymeslot.Utils.ReminderUtils

  @max_reminders 3
  @max_reminder_seconds 365 * 24 * 60 * 60

  @doc """
  Validates a reminder configuration value from form input.

  Accepts `nil`, an empty string, a JSON string, a map, or a list of
  reminder maps. Returns `{:ok, normalised_reminders}` on success or
  `{:error, %{reminder_config: message}}` on failure.
  """
  @spec validate_reminder_config(any(), map()) :: {:ok, list()} | {:error, map()}
  def validate_reminder_config(nil, _metadata), do: {:ok, []}
  def validate_reminder_config("", _metadata), do: {:ok, []}

  def validate_reminder_config(reminder_config, _metadata) do
    with {:ok, reminders} <- parse_and_normalize_reminders(reminder_config),
         :ok <- validate_reminders_policy(reminders) do
      {:ok, reminders}
    else
      {:error, message} -> {:error, %{reminder_config: message}}
    end
  end

  @doc """
  Parses and normalises reminder input into a list of reminder maps.

  Accepts a JSON string, a map (keyed by index), or a list of reminder
  maps. Each reminder is normalised via `ReminderUtils.normalize_reminder_string_keys/1`.
  """
  @spec parse_and_normalize_reminders(any()) :: {:ok, list()} | {:error, String.t()}
  def parse_and_normalize_reminders(reminders) when is_binary(reminders) do
    case Jason.decode(reminders) do
      {:ok, decoded} -> parse_and_normalize_reminders(decoded)
      _invalid -> {:error, "Invalid reminder settings format"}
    end
  end

  def parse_and_normalize_reminders(reminders) when is_map(reminders) do
    reminders
    |> Map.values()
    |> parse_and_normalize_reminders()
  end

  def parse_and_normalize_reminders(reminders) when is_list(reminders) do
    results = Enum.map(reminders, &ReminderUtils.normalize_reminder_string_keys/1)

    if Enum.any?(results, &match?({:error, _reason}, &1)) do
      {:error, "Reminder settings must include valid values and units"}
    else
      {:ok, Enum.map(results, fn {:ok, reminder} -> reminder end)}
    end
  end

  def parse_and_normalize_reminders(_other), do: {:error, "Invalid reminder settings format"}

  @doc """
  Enforces reminder policy constraints: maximum count, uniqueness, and
  maximum interval.
  """
  @spec validate_reminders_policy(list()) :: :ok | {:error, String.t()}
  def validate_reminders_policy(reminders) do
    cond do
      length(reminders) > @max_reminders ->
        {:error, "You can configure up to #{@max_reminders} reminders"}

      ReminderUtils.duplicate_reminders?(reminders) ->
        {:error, "Reminder settings must be unique"}

      Enum.any?(reminders, &reminder_exceeds_max?/1) ->
        {:error, "Reminders cannot be set for more than 1 year in advance"}

      true ->
        :ok
    end
  end

  @doc """
  Returns `true` if a single reminder exceeds the maximum allowed interval
  (1 year).
  """
  @spec reminder_exceeds_max?(map()) :: boolean()
  def reminder_exceeds_max?(%{value: v, unit: u}) do
    seconds = ReminderUtils.reminder_interval_seconds(v, u)
    seconds > @max_reminder_seconds
  end
end
