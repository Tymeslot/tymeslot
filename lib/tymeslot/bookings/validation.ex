defmodule Tymeslot.Bookings.Validation do
  @moduledoc """
  Pure validation functions for booking-related data.

  This module contains only pure functions with no side effects or database calls.
  All validation is based on the data passed in as parameters.
  """

  alias Tymeslot.Availability.{Calculate, Events, Offer}
  alias Tymeslot.Bookings.Errors
  alias Tymeslot.Bookings.ScheduleCheck
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Utils.{DateTimeUtils, TimeRange}
  alias Tymeslot.Utils.DateTimeUtils.Duration

  @default_min_advance_hours 3
  @default_max_advance_days 365

  @typedoc "A calendar event with start and optional end time, used for conflict checking."
  @type calendar_event :: %{
          required(:start_time) => DateTime.t() | Date.t(),
          required(:end_time) => DateTime.t() | Date.t() | nil
        }

  @typedoc "Optional scheduling configuration for booking time validation."
  @type scheduling_config :: %{
          optional(:min_advance_hours) => non_neg_integer(),
          optional(:max_advance_booking_days) => non_neg_integer(),
          optional(:buffer_before_minutes) => non_neg_integer(),
          optional(:buffer_after_minutes) => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc """
  Parses and validates meeting time strings into DateTime objects.

  ## Examples

      iex> Validation.parse_meeting_times("2024-01-01", "10:00 AM", 30, "America/New_York")
      {:ok, {start_datetime, end_datetime}}

      iex> Validation.parse_meeting_times("invalid", "10:00 AM", 30, "America/New_York")
      {:error, :invalid_datetime}
  """
  @spec parse_meeting_times(String.t(), String.t(), integer() | String.t(), String.t()) ::
          {:ok, {DateTime.t(), DateTime.t()}} | {:error, :invalid_datetime}
  def parse_meeting_times(date_string, time_string, duration, timezone) do
    with {:ok, date} <- parse_date(date_string),
         {:ok, time} <- safe_parse_time_slot(time_string),
         {:ok, duration_minutes} <- parse_duration(duration),
         {:ok, start_datetime} <- DateTimeUtils.resolve_local(date, time, timezone),
         end_datetime <- DateTime.add(start_datetime, duration_minutes, :minute) do
      {:ok, {start_datetime, end_datetime}}
    else
      _parse_error -> {:error, :invalid_datetime}
    end
  end

  @typedoc """
  Why a booking time is refused: it is not in the future (`:in_past`), it
  falls inside the schedule's minimum notice (`{:too_soon, hours}`), or
  beyond its booking window (`{:too_far_ahead, days}`).
  """
  @type booking_time_refusal ::
          :in_past | {:too_soon, non_neg_integer()} | {:too_far_ahead, non_neg_integer()}

  @doc """
  Validates that a booking time is in the future, outside the minimum notice
  and inside the booking window that `config` sets (`:min_advance_hours`,
  `:max_advance_booking_days`, defaulting to 3 hours and 365 days).
  `:current_time` in `config` stands in for the clock.

  Pure validation based on time calculations only.
  """
  @spec validate_booking_time(DateTime.t(), scheduling_config()) ::
          :ok | {:error, booking_time_refusal()}
  def validate_booking_time(start_datetime, config \\ %{}) do
    current_time = Map.get(config, :current_time, Clock.utc_now())
    min_notice_hours = Map.get(config, :min_advance_hours, @default_min_advance_hours)
    max_booking_days = Map.get(config, :max_advance_booking_days, @default_max_advance_days)

    cond do
      DateTime.compare(start_datetime, current_time) != :gt ->
        {:error, :in_past}

      not TimeRange.meets_minimum_notice?(start_datetime, current_time, min_notice_hours * 60) ->
        {:error, {:too_soon, min_notice_hours}}

      not TimeRange.within_booking_window?(start_datetime, current_time, max_booking_days) ->
        {:error, {:too_far_ahead, max_booking_days}}

      true ->
        :ok
    end
  end

  @doc """
  Checks if a time slot has conflicts with existing events.

  `buffers` is `{before, after}`: the minutes that must stay free before the
  slot starts and after it ends. They pad the slot, never the events.

  Events are first filtered through `CalendarEvent.blocking?/1` so that
  cancelled, declined, and `TRANSP:TRANSPARENT` (free/busy = free) events
  never block a booking, matching the contract that `Availability.Conflicts`
  enforces for the display path. They are then turned into instants by
  `Availability.Events.convert_events_to_timezone/3`, the conversion the
  display path uses, so an all-day event blocks the owner's local day here
  exactly as it does on the booking page, and an event without an end blocks
  the same stretch on both.
  """
  @spec check_slot_availability(
          DateTime.t(),
          DateTime.t(),
          [calendar_event()],
          TimeRange.buffers(),
          String.t()
        ) :: :ok | {:error, :slot_unavailable}
  def check_slot_availability(start_datetime, end_datetime, events, buffers, owner_timezone) do
    intervals =
      events
      |> Enum.filter(&CalendarEvent.blocking?/1)
      |> Events.convert_events_to_timezone(owner_timezone, "Etc/UTC")

    if TimeRange.has_conflict_with_events?(start_datetime, end_datetime, intervals, buffers) do
      {:error, :slot_unavailable}
    else
      :ok
    end
  end

  @doc """
  Validates that a time slot has no conflicts with existing events.

  Takes calendar events and checks for overlaps, with all-day events anchored
  in the config's `:owner_timezone`.
  """
  @spec validate_no_conflicts(DateTime.t(), DateTime.t(), [calendar_event()], scheduling_config()) ::
          :ok | {:error, :slot_unavailable}
  def validate_no_conflicts(start_datetime, end_datetime, events, config) do
    check_slot_availability(
      start_datetime,
      end_datetime,
      events,
      Calculate.config_buffers(config),
      Map.get(config, :owner_timezone, "Etc/UTC")
    )
  end

  @doc """
  Parses and validates the requested new time for a reschedule off
  `old_meeting`, returning the new slot's times.

  Shared by the whole-meeting reschedule (`Tymeslot.Bookings.Reschedule`)
  and move-my-seat (`Tymeslot.Bookings.RescheduleSeat`), so both agree on
  what counts as a valid new slot. The new slot keeps the old meeting's
  duration, never `params.duration`: a reschedule moves a meeting in time,
  it does not change its length, and `params.duration` is an
  attendee-supplied URL slug with no binding to what the meeting is (this
  holds even when the meeting type has been deleted and `meeting_type` is
  `nil`). `ScheduleCheck` is stepped by the duration the booking page's grid
  is drawn with (`Offer.duration_minutes/2`, the meeting type's current
  one), so a slot the page just offered is not refused after a host edits
  the type; only the check's step size follows the type.

  `meeting_type` and `config` are resolved once by the caller and threaded
  through rather than re-fetched: two reads of the same rows leave a window
  in which a host edit between them is answered differently by each, and
  the calendar check that follows needs the same buffer and notice rules.
  """
  @spec prepare_new_times(map(), map(), map() | nil, map()) ::
          {:ok, %{start_time: DateTime.t(), end_time: DateTime.t(), duration_minutes: integer()}}
          | {:error, term()}
  def prepare_new_times(params, old_meeting, meeting_type, config) do
    duration_minutes = old_meeting.duration
    schedule_check_duration_minutes = Offer.duration_minutes(meeting_type, duration_minutes)

    with {:ok, {start_datetime, end_datetime}} <-
           parse_meeting_times(
             params.date,
             params.time,
             duration_minutes,
             params.user_timezone
           ),
         {:ok, date} <- parse_date(params.date),
         :ok <- validate_booking_time(start_datetime, config),
         :ok <-
           ScheduleCheck.validate_slot_on_schedule(
             date,
             start_datetime,
             schedule_check_duration_minutes,
             params.user_timezone,
             config,
             old_meeting.organizer_user_id
           ) do
      {:ok,
       %{
         start_time: start_datetime,
         end_time: end_datetime,
         duration_minutes: duration_minutes
       }}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, Errors.classify_schedule_check_reason(reason) || reason}

      {:error, _reason} = error ->
        error
    end
  end

  # Private functions

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp parse_date(_invalid), do: {:error, :invalid_date}

  # `TimeSlots.parse_time_slot/1` raises on unparsable input; its underlying
  # parser already reports the failure as a tuple, so call that directly and
  # translate the reason rather than round-tripping through an exception.
  defp safe_parse_time_slot(time_string) do
    case DateTimeUtils.parse_time_string(time_string) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, :invalid_time}
    end
  end

  defp parse_duration(duration) when is_integer(duration), do: {:ok, duration}

  # A booking names its length; one that cannot be read is refused rather
  # than booked at a default length the booker never chose.
  defp parse_duration(duration) when is_binary(duration) do
    case Duration.parse_minutes(duration) do
      {:ok, minutes} when minutes > 0 -> {:ok, minutes}
      _not_a_length -> {:error, :invalid_duration}
    end
  end

  defp parse_duration(_invalid), do: {:error, :invalid_duration}
end
