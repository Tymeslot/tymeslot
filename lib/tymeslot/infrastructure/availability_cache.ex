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
  Cache key helpers for consistent key generation.
  """
  @spec month_availability_key(integer(), integer(), integer(), String.t(), integer() | nil) ::
          {atom(), integer(), integer(), integer(), String.t(), integer() | nil}
  def month_availability_key(user_id, year, month, timezone, duration) do
    {:month_availability, user_id, year, month, timezone, duration}
  end

  @doc """
  Cache key for range-based availability lookups.

  `meeting_type_id` is part of the key because per-meeting-type booking
  limits make availability differ between types sharing a duration.
  """
  @spec availability_range_key(
          integer(),
          Date.t(),
          Date.t(),
          String.t(),
          integer() | nil,
          integer() | nil
        ) ::
          {atom(), integer(), Date.t(), Date.t(), String.t(), integer() | nil, integer() | nil}
  def availability_range_key(user_id, start_date, end_date, timezone, duration, meeting_type_id) do
    {:range_availability, user_id, start_date, end_date, timezone, duration, meeting_type_id}
  end

  @doc """
  Invalidates all cached availability data for a user.
  Call after any mutation to the user's availability schedule or bookings.
  A `nil` user id is a no-op, so callers can pass `meeting.organizer_user_id`
  unconditionally.
  """
  @spec invalidate_for_user(integer() | nil) :: :ok
  def invalidate_for_user(nil), do: :ok

  def invalidate_for_user(user_id) do
    invalidate_pattern({:month_availability, user_id, :_, :_, :_, :_})
    invalidate_pattern({:range_availability, user_id, :_, :_, :_, :_, :_})
    :ok
  end
end
