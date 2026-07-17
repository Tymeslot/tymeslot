defmodule Tymeslot.Infrastructure.AvailabilityCache do
  @moduledoc """
  ETS-based cache for availability data using the shared CacheStore.
  """
  use Tymeslot.Infrastructure.CacheStore,
    table_name: :availability_cache,
    default_ttl: :timer.minutes(2),
    cleanup_interval: :timer.minutes(5)

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
