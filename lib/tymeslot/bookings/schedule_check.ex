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

  alias Tymeslot.Availability.Calculate

  @doc """
  Returns `:ok` when the schedule described by `config` offers
  `start_datetime` on `date` for `duration_minutes`, or
  `{:error, :slot_not_offered}` otherwise.
  """
  @spec validate_slot_on_schedule(Date.t(), DateTime.t(), pos_integer(), String.t(), map()) ::
          :ok | {:error, :slot_not_offered}
  def validate_slot_on_schedule(date, start_datetime, duration_minutes, user_timezone, config) do
    if Calculate.offers_slot?(
         date,
         start_datetime,
         duration_minutes,
         user_timezone,
         config.owner_timezone,
         config
       ) do
      :ok
    else
      {:error, :slot_not_offered}
    end
  end
end
