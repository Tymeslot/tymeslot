defmodule Tymeslot.Availability do
  @moduledoc """
  The one call a write makes when it changes what a host's booking page
  offers.

  The slot engine caches a host's offered days and the booking-window events
  it folds them from (`Tymeslot.Infrastructure.AvailabilityCache`), keyed by
  user. Anything that changes an input of that computation (the host's
  timezone or booking limits, a schedule, time off, a meeting type, a
  booking, a calendar or its events) calls `changed/1` once it has committed,
  so the next page view computes afresh rather than serving the old answer
  for the cache's lifetime.

  It never fails: a write that succeeded must not turn into an error because
  a cache could not be cleared, and a missing owner leaves nothing to clear.
  """

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema

  @doc """
  Records that the availability of a host changed.

  Takes the host's user id, or a record that names the host: their profile,
  or an availability schedule (the user owning its profile). `nil` is a
  no-op, so callers can pass an optional owner as is.
  """
  @spec changed(integer() | ProfileSchema.t() | AvailabilityScheduleSchema.t() | nil) :: :ok
  def changed(nil), do: :ok

  def changed(user_id) when is_integer(user_id),
    do: AvailabilityCache.invalidate_for_user(user_id)

  def changed(%ProfileSchema{user_id: user_id}), do: changed(user_id)

  # Resolved through the profile id rather than the schedule's own row, so a
  # schedule that was just deleted still reaches its owner.
  def changed(%AvailabilityScheduleSchema{profile_id: profile_id}),
    do: profile_id |> ProfileQueries.user_id_for_profile() |> changed()
end
