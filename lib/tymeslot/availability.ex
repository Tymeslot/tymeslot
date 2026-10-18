defmodule Tymeslot.Availability do
  @moduledoc """
  What a host's booking page offers, as their own calendar sees it, and the
  one call a write makes when it changes.

  `bookable_windows/4` and `next_bookable/3` answer the calendar's question
  (when can guests book this meeting type?) from the same starts the booking
  page labels (`Tymeslot.Availability.BookableWindows`).

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
  alias Tymeslot.Availability.BookableWindows
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema

  @doc """
  The windows guests can book `meeting_type_id` in over `from..to`, the
  organiser's dates. See `Tymeslot.Availability.BookableWindows.windows/4`.
  """
  @spec bookable_windows(pos_integer(), pos_integer(), Date.t(), Date.t()) ::
          {:ok, [BookableWindows.window()]}
          | {:error, :not_found | :invalid_range | :range_too_long | term()}
  defdelegate bookable_windows(user_id, meeting_type_id, from, to),
    to: BookableWindows,
    as: :windows

  @doc """
  The first bookable start at or after `after_at`, or nil. See
  `Tymeslot.Availability.BookableWindows.next/3`.
  """
  @spec next_bookable(pos_integer(), pos_integer(), DateTime.t()) ::
          {:ok, DateTime.t() | nil} | {:error, :not_found | term()}
  defdelegate next_bookable(user_id, meeting_type_id, after_at), to: BookableWindows, as: :next

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
