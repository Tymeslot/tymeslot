defmodule Tymeslot.Utils.ReminderUtils do
  @moduledoc """
  Utility functions for meeting reminders.
  """

  @valid_reminder_units ["minutes", "hours", "days"]

  @doc """
  Formats a reminder interval into a human-readable label.
  """
  @spec format_reminder_label(integer() | String.t(), String.t()) :: String.t()
  def format_reminder_label(value, unit) do
    value = parse_reminder_value(value)
    unit = normalize_reminder_unit(unit)

    unit_label =
      case {value, unit} do
        {1, "minutes"} -> "minute"
        {1, "hours"} -> "hour"
        {1, "days"} -> "day"
        {_value, "minutes"} -> "minutes"
        {_value, "hours"} -> "hours"
        {_value, "days"} -> "days"
        _other -> "minutes"
      end

    "#{value} #{unit_label}"
  end

  @doc """
  Normalizes a reminder map or parameters into a consistent format with atom keys.
  Strict validation: returns {:error, :invalid_reminder} if unit is invalid.
  """
  @spec normalize_reminder(map() | nil) :: {:ok, map()} | {:error, :invalid_reminder}
  def normalize_reminder(%{"value" => value, "unit" => unit}) do
    normalize_reminder(%{value: value, unit: unit})
  end

  def normalize_reminder(%{value: value, unit: unit}) do
    with {:ok, normalized_value} <- validate_reminder_value(value),
         true <- unit in @valid_reminder_units do
      {:ok, %{value: normalized_value, unit: unit}}
    else
      _other -> {:error, :invalid_reminder}
    end
  end

  def normalize_reminder(_value), do: {:error, :invalid_reminder}

  @doc """
  Normalizes reminder parameters that may use string keys.
  Alias for normalize_reminder/1 for clarity in form processing.
  """
  @spec normalize_reminder_string_keys(map()) :: {:ok, map()} | {:error, :invalid_reminder}
  def normalize_reminder_string_keys(params), do: normalize_reminder(params)

  @doc """
  Normalizes a list of reminders, filtering out invalid ones.
  Always returns a list of maps with atom keys.
  """
  @spec normalize_reminders(list() | any()) :: [map()]
  def normalize_reminders(reminders) when is_list(reminders) do
    reminders
    |> Enum.map(&normalize_reminder/1)
    |> Enum.flat_map(fn
      {:ok, reminder} -> [reminder]
      _other -> []
    end)
  end

  def normalize_reminders(_value), do: []

  @doc """
  Calculates the interval in seconds for a reminder.
  """
  @spec reminder_interval_seconds(integer() | String.t(), String.t()) :: integer()
  def reminder_interval_seconds(value, unit) do
    value = parse_reminder_value(value)
    unit = normalize_reminder_unit(unit)

    multiplier =
      case unit do
        "minutes" -> 60
        "hours" -> 3600
        "days" -> 86_400
        _other -> 60
      end

    value * multiplier
  end

  @doc """
  Parses a reminder value into an integer.
  Lenient: allows trailing text (e.g., "30 minutes").
  """
  @spec parse_reminder_value(integer() | String.t() | any()) :: integer()
  def parse_reminder_value(value) when is_integer(value) and value > 0, do: value

  def parse_reminder_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int > 0 -> int
      _other -> 30
    end
  end

  def parse_reminder_value(_value), do: 30

  @doc """
  Validates a reminder value.
  Lenient: allows trailing text.
  """
  @spec validate_reminder_value(integer() | String.t() | any()) ::
          {:ok, integer()} | {:error, :invalid_value}
  def validate_reminder_value(value) when is_integer(value) and value > 0, do: {:ok, value}

  def validate_reminder_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int > 0 -> {:ok, int}
      _other -> {:error, :invalid_value}
    end
  end

  def validate_reminder_value(_value), do: {:error, :invalid_value}

  @doc """
  Normalizes a reminder unit.
  Lenient: handles strings containing units (e.g., "30 minutes").
  """
  @spec normalize_reminder_unit(String.t() | any()) :: String.t()
  def normalize_reminder_unit(unit) when unit in ["minutes", "hours", "days"], do: unit

  def normalize_reminder_unit(unit) when is_binary(unit) do
    unit = String.downcase(unit)

    cond do
      unit =~ "minute" -> "minutes"
      unit =~ "hour" -> "hours"
      unit =~ "day" -> "days"
      true -> "minutes"
    end
  end

  def normalize_reminder_unit(_value), do: "minutes"

  @doc """
  Checks if a list of reminders contains duplicates.
  Normalizes all reminders to minutes before comparison to detect equivalent intervals
  (e.g., "60 minutes" and "1 hour" are considered duplicates).
  """
  @spec duplicate_reminders?([map()]) :: boolean()
  def duplicate_reminders?(reminders) when is_list(reminders) do
    normalized_minutes =
      Enum.flat_map(reminders, fn
        %{"value" => v, "unit" => u} ->
          minutes = convert_to_minutes(v, u)
          [minutes]

        %{value: v, unit: u} ->
          minutes = convert_to_minutes(v, u)
          [minutes]

        _other ->
          []
      end)

    MapSet.size(MapSet.new(normalized_minutes)) != length(normalized_minutes)
  end

  # Converts reminder value and unit to total minutes for duplicate detection
  defp convert_to_minutes(value, unit) do
    value = parse_reminder_value(value)
    unit = normalize_reminder_unit(unit)

    case unit do
      "minutes" -> value
      "hours" -> value * 60
      "days" -> value * 24 * 60
      _other -> value
    end
  end
end
