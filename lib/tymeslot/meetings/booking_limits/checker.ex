defmodule Tymeslot.Meetings.BookingLimits.Checker do
  @moduledoc """
  Wires `Tymeslot.Meetings.BookingLimits` to booking data: fetches the
  relevant slot-occupying bookings once and returns ready-to-use checks.

  When no cap is configured the functions bail out before touching the
  database, so hosts without limits pay nothing.
  """

  alias Tymeslot.Meetings.BookingLimits
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Profiles

  @doc """
  Builds a `(DateTime.t() -> boolean())` closure answering "would a booking
  at this instant exceed a limit?" for slots rendered in
  `start_date..end_date`, or `nil` when no cap is configured.

  `profile_settings` is a profile struct or settings map carrying the
  account-wide caps and the host timezone; `meeting_type` carries the
  per-type caps (may be `nil`).

  Options:
    * `:exclude_uid` — omit one meeting from the counts (reschedule self-exclusion).
  """
  @spec build_slot_checker(integer(), map() | nil, map() | nil, Date.t(), Date.t(), keyword()) ::
          (DateTime.t() -> boolean()) | nil
  def build_slot_checker(
        organizer_user_id,
        profile_settings,
        meeting_type,
        start_date,
        end_date,
        opts \\ []
      ) do
    with_context(
      organizer_user_id,
      profile_settings,
      meeting_type,
      start_date,
      end_date,
      opts,
      fn context ->
        &BookingLimits.slot_blocked?(context, &1)
      end
    )
  end

  @doc """
  Booking-time check: whether a booking starting at `start_time` is within
  every configured cap. Returns `:ok` when no cap is configured.

  Accepts the same options as `build_slot_checker/6`.
  """
  @spec check_booking_allowed(integer(), map() | nil, map() | nil, DateTime.t(), keyword()) ::
          :ok | {:error, :booking_limit_reached}
  def check_booking_allowed(
        organizer_user_id,
        profile_settings,
        meeting_type,
        %DateTime{} = start_time,
        opts \\ []
      ) do
    host_timezone = host_timezone(profile_settings)
    day = BookingLimits.day_key(start_time, host_timezone)

    case with_context(
           organizer_user_id,
           profile_settings,
           meeting_type,
           day,
           day,
           opts,
           fn context ->
             BookingLimits.check_booking_allowed(context, start_time)
           end
         ) do
      nil -> :ok
      result -> result
    end
  end

  defp with_context(
         organizer_user_id,
         profile_settings,
         meeting_type,
         start_date,
         end_date,
         opts,
         fun
       ) do
    limits = BookingLimits.limits_for(profile_settings, meeting_type)

    if BookingLimits.enabled?(limits) do
      host_timezone = host_timezone(profile_settings)

      {from_utc, to_utc} =
        BookingLimits.expanded_query_window(start_date, end_date, host_timezone)

      rows =
        MeetingQueries.list_live_booking_starts(
          organizer_user_id,
          from_utc,
          to_utc,
          Keyword.take(opts, [:exclude_uid])
        )

      fun.(BookingLimits.build_context(limits, host_timezone, rows))
    end
  end

  defp host_timezone(profile_settings) do
    (profile_settings && Map.get(profile_settings, :timezone)) || Profiles.get_default_timezone()
  end
end
