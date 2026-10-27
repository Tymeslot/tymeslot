defmodule Tymeslot.Infrastructure.AvailabilityCache do
  @moduledoc """
  ETS-based cache for availability data using the shared CacheStore.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :availability_cache,
    default_ttl: :timer.minutes(2),
    cleanup_interval: :timer.minutes(5)

  @doc """
  Like `get_or_compute/3`, but never caches an `{:error, _}` result.

  Calendar fetch failures (`:some_calendars_unavailable`,
  `:all_calendars_unavailable`) are meant to be transient and retried on the
  very next request, not memoised for the full TTL — otherwise a single
  timed-out CalDAV request would blank the booking page for up to
  #{div(:timer.minutes(2), :timer.seconds(1))} seconds with no way to recover
  before the entry expires.
  """
  @spec get_or_compute_events(term(), (-> {:ok, any()} | {:error, any()})) ::
          {:ok, any()} | {:error, any()}
  def get_or_compute_events(key, fun) do
    get_or_compute(key, fun, @default_ttl, cache_errors: false)
  end

  @doc """
  Cache key for range-based availability lookups.

  `meeting_type_id` is part of the key because per-meeting-type booking
  limits make availability differ between types sharing a duration, and
  because group meeting types cache their own seat-overlaid range maps; solo
  lookups with no type pass nil. `moving_uid` is part of it
  too, because a reschedule page does not count the meeting being moved
  against those limits; pass only a uid already proven to be the organiser's,
  so visitor input cannot mint entries. Nil for every other page.
  """
  @spec availability_range_key(
          integer(),
          Date.t(),
          Date.t(),
          String.t(),
          integer() | nil,
          integer() | nil,
          String.t() | nil
        ) ::
          {atom(), integer(), Date.t(), Date.t(), String.t(), integer() | nil, integer() | nil,
           String.t() | nil}
  def availability_range_key(
        user_id,
        start_date,
        end_date,
        timezone,
        duration,
        meeting_type_id,
        moving_uid
      ) do
    {:range_availability, user_id, start_date, end_date, timezone, duration, meeting_type_id,
     moving_uid}
  end

  @doc """
  Cache key for the host's whole booking window of calendar events.

  `Tymeslot.Integrations.Calendar.Events.get_calendar_events/3` ignores
  the date it is handed and always fetches `today .. today +
  advance_booking_days`, so the user id is the fetch's entire input and
  the entire key. Deliberately *not* keyed on a display range: that is
  what makes one cached fetch serve every month a booking page can walk
  to, rather than one identical provider round trip per rendered month.
  """
  @spec booking_window_events_key(integer()) :: {atom(), integer()}
  def booking_window_events_key(user_id) do
    {:booking_window_events, user_id}
  end

  @doc """
  Invalidates all cached availability data for a user.
  Call after any mutation to the user's availability schedule or bookings, and
  after any committed seat change on one of the user's group meeting types.
  A `nil` user id is a no-op, so callers can pass `meeting.organizer_user_id`
  unconditionally.

  Both kinds of entry go in one step. A range computation reads the cached
  booking-window events, so with the ranges dropped first and the events a
  moment later, a range computed in between would fold the old events and
  be stored as current.
  """
  @spec invalidate_for_user(integer() | nil) :: :ok
  def invalidate_for_user(nil), do: :ok

  def invalidate_for_user(user_id) do
    invalidate_together([
      {:pattern, {:range_availability, user_id, :_, :_, :_, :_, :_, :_}},
      {:key, booking_window_events_key(user_id)}
    ])

    :ok
  end
end
