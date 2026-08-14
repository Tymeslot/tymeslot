defmodule TymeslotWeb.Dashboard.Availability.ListComponent.BreakHelpers do
  @moduledoc "Pure helpers for break and schedule operations in the availability list."

  use Gettext, backend: TymeslotWeb.Gettext

  # Fields the add-break form renders an inline error under; everything else
  # has no home in the form and is surfaced as a flash instead.
  @form_fields [:label, :start_time, :end_time]

  @doc "Find a break by ID in a weekly schedule."
  @spec find_break_info([map()], integer()) :: map() | nil
  def find_break_info(weekly_schedule, break_id) do
    Enum.reduce_while(weekly_schedule, nil, fn day_availability, acc ->
      break = Enum.find(day_availability.breaks || [], &(&1.id == break_id))
      if break, do: {:halt, break}, else: {:cont, acc}
    end)
  end

  @doc "Replace a day entry in the schedule with an updated version."
  @spec update_day_in_schedule([map()], map()) :: [map()]
  def update_day_in_schedule(schedule, updated_day) do
    Enum.map(schedule, fn day_avail ->
      if day_avail.day_of_week == updated_day.day_of_week do
        updated_day
      else
        day_avail
      end
    end)
  end

  @doc """
  Format a `Time` struct to 24h "HH:MM", or return an empty string for nil.

  This is the wire format, not a display format: it produces the value a time
  dropdown submits and `Tymeslot.Availability` parses, so it stays 24h whatever
  clock the organiser reads. To show a time to someone, use
  `Tymeslot.Utils.DateTimeUtils.TimeFormat.format/2` with their `time_format`.
  """
  @spec format_time(Time.t() | nil) :: String.t()
  def format_time(nil), do: ""
  def format_time(time), do: Calendar.strftime(time, "%H:%M")

  @doc """
  Parse a day-of-week integer from a string or a params map containing a \"day\" key.
  Returns `{:ok, day}` for valid integers in 1..7, or `{:error, :invalid_day}`.
  """
  @spec parse_day(String.t() | map()) :: {:ok, 1..7} | {:error, :invalid_day}
  def parse_day(params_or_str) do
    str =
      cond do
        is_map(params_or_str) -> params_or_str["day"] || ""
        is_binary(params_or_str) -> params_or_str
        true -> ""
      end

    case Integer.parse(str) do
      {day, ""} when day in 1..7 -> {:ok, day}
      _other -> {:error, :invalid_day}
    end
  end

  @doc """
  Turn a rejected break changeset into display strings.

  Returns `{field_errors, general_messages}`: `field_errors` is the
  `%{field => message}` map the add-break form renders inline, and
  `general_messages` holds the errors with no field on the form (`:base`,
  associations) for the caller to flash.

  Breaks are checked against the day's work hours twice, in
  `Tymeslot.Availability.Breaks` and again in the schema changeset, so a
  single mistake arrives as two errors on one field. Both map to the same
  message and collapse into one entry.
  """
  @spec break_error_messages(Ecto.Changeset.t()) :: {%{atom() => String.t()}, [String.t()]}
  def break_error_messages(%Ecto.Changeset{errors: errors}) do
    {field_errors, general_errors} =
      errors
      |> Enum.map(fn {field, {message, _opts}} -> {field, display_message(field, message)} end)
      |> Enum.split_with(fn {field, _message} -> field in @form_fields end)

    {Map.new(field_errors), general_errors |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
  end

  defp display_message(:start_time, message)
       when message in ["cannot be before work hours", "must be within work hours"] do
    dgettext("dashboard_availability", "Break must start within this day's working hours")
  end

  defp display_message(:end_time, message)
       when message in ["cannot be after work hours", "must be within work hours"] do
    dgettext("dashboard_availability", "Break must end within this day's working hours")
  end

  defp display_message(:end_time, "must be after start time") do
    dgettext("dashboard_availability", "End time must be after start time")
  end

  defp display_message(_field, "Break times overlap with existing break") do
    dgettext("dashboard_availability", "This break overlaps an existing break")
  end

  defp display_message(_field, _message) do
    dgettext("dashboard_availability", "Break could not be saved")
  end
end
