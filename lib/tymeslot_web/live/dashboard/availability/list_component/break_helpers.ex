defmodule TymeslotWeb.Dashboard.Availability.ListComponent.BreakHelpers do
  @moduledoc "Pure helpers for break and schedule operations in the availability list."

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Window
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Helpers.LocaleFormat

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
  Why a copy stopped: a break saved before its day's hours were narrowed
  falls outside them, so it cannot be copied anywhere with the same hours.
  Names the day and the break so the host can move or delete it.
  """
  @spec stale_break_message(map(), map(), String.t() | nil) :: String.t()
  def stale_break_message(day, break, time_format) do
    dgettext(
      "dashboard_availability",
      "The %{break} break on %{day} falls outside that day's hours. Move or delete it, then try again.",
      break: break_time_label(day, break, time_format),
      day:
        LocaleFormat.format_weekday_name(
          day.day_of_week,
          Gettext.get_locale(TymeslotWeb.Gettext),
          :full
        )
    )
  end

  @doc """
  A break's times for its chip, with "(+1)" on a time that falls on the day
  after the day's own date (hours that end the next day).
  """
  @spec break_time_label(map(), map(), String.t() | nil) :: String.t()
  def break_time_label(day_availability, break, time_format) do
    start_label = clock(day_availability, break.start_time, :start, time_format)
    end_label = clock(day_availability, break.end_time, :end, time_format)
    "#{start_label} - #{end_label}"
  end

  defp clock(day_availability, time, edge, time_format) do
    TimeOptions.time_label(time, Window.next_day?(day_availability, time, edge), time_format)
  end

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
  """
  @spec break_error_messages(Ecto.Changeset.t()) :: {%{atom() => String.t()}, [String.t()]}
  def break_error_messages(%Ecto.Changeset{errors: errors}) do
    {field_errors, general_errors} =
      errors
      |> Enum.map(fn {field, {message, _opts}} -> {field, display_message(field, message)} end)
      |> Enum.split_with(fn {field, _message} -> field in @form_fields end)

    {Map.new(field_errors), general_errors |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
  end

  defp display_message(:start_time, "must be within work hours") do
    dgettext("dashboard_availability", "Break must start within this day's working hours")
  end

  defp display_message(:end_time, "must be within work hours") do
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
