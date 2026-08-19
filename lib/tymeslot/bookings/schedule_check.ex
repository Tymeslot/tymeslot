defmodule Tymeslot.Bookings.ScheduleCheck do
  @moduledoc """
  Confirms a candidate booking time is one the organiser's schedule actually
  offers.

  Shared by `Tymeslot.Bookings.Create` and `Tymeslot.Bookings.Reschedule` so
  both paths enforce the same rule: a booking may not land on a time the
  schedule's weekly windows, breaks and overrides never offered, re-derived
  from the persisted schedule rather than trusted from the submitted date and
  time. Conflicts with other meetings are not this check's business — each
  caller's own calendar/DB conflict check owns those.
  """

  require Logger

  alias Tymeslot.Availability.Calculate

  @doc """
  Returns `:ok` when the schedule described by `config` offers
  `start_datetime` on `date` for `duration_minutes`, or an error atom
  otherwise: `{:error, :slot_not_offered}` when the schedule was read
  successfully and genuinely never offered that time, or
  `{:error, :slot_availability_unverifiable}` when the schedule itself
  couldn't be read (a distinct reason from a real refusal, kept apart so a
  caller — or a log line reading these atoms later — can tell "nobody took
  it, the schedule never had it" apart from "we couldn't tell").

  Both refusals are logged here, once, on behalf of every caller: the
  `:slot_taken` message a booker eventually sees on either path is otherwise
  indistinguishable between an actual conflict and a schedule gate that
  refused for its own reasons.
  """
  @spec validate_slot_on_schedule(Date.t(), DateTime.t(), pos_integer(), String.t(), map()) ::
          :ok | {:error, :slot_not_offered | :slot_availability_unverifiable}
  def validate_slot_on_schedule(date, start_datetime, duration_minutes, user_timezone, config) do
    case Calculate.offers_slot(
           date,
           start_datetime,
           duration_minutes,
           user_timezone,
           config.owner_timezone,
           config
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        Logger.info(
          "Schedule refused a booking: requested time is not on the offered schedule",
          date: Date.to_iso8601(date),
          start_datetime: DateTime.to_iso8601(start_datetime)
        )

        {:error, :slot_not_offered}

      {:error, reason} ->
        Logger.warning(
          "Schedule availability could not be determined, refusing booking",
          date: Date.to_iso8601(date),
          start_datetime: DateTime.to_iso8601(start_datetime),
          reason: inspect(reason)
        )

        {:error, :slot_availability_unverifiable}
    end
  end
end
