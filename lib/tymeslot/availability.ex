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

  `changed/1` also says so: it broadcasts `{:availability_changed, user_id}`
  on the topic `"availability:<user_id>"`, so a page showing the host's
  bookable times (their calendar) can recompute them. `subscribe/1` joins
  that topic.

  It never fails: a write that succeeded must not turn into an error because
  a cache could not be cleared, and a missing owner leaves nothing to clear.
  """

  require Logger

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.BookableWindows
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Availability.WeeklyHours
  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ProfileSchema

  @doc """
  A meeting length in minutes, from a duration label such as `"45min"` or a
  number of minutes; 30 for anything that is not a positive length. See
  `Tymeslot.Availability.TimeSlots.parse_duration/1`.
  """
  @spec parse_duration(String.t() | integer()) :: integer()
  defdelegate parse_duration(duration), to: TimeSlots

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

  def changed(user_id) when is_integer(user_id) do
    AvailabilityCache.invalidate_for_user(user_id)
    broadcast(user_id)
  end

  def changed(%ProfileSchema{user_id: user_id}), do: changed(user_id)

  # Resolved through the profile id rather than the schedule's own row, so a
  # schedule that was just deleted still reaches its owner.
  def changed(%AvailabilityScheduleSchema{profile_id: profile_id}),
    do: profile_id |> ProfileQueries.user_id_for_profile() |> changed()

  @doc """
  Subscribes the calling process to `user_id`'s availability changes: it
  receives `{:availability_changed, user_id}` after each `changed/1`.
  """
  @spec subscribe(integer()) :: :ok | {:error, term()}
  def subscribe(user_id) when is_integer(user_id),
    do: Phoenix.PubSub.subscribe(Tymeslot.PubSub, topic(user_id))

  defp topic(user_id), do: "availability:#{user_id}"

  # A write that succeeded must not fail because nobody could be told.
  defp broadcast(user_id) do
    case Phoenix.PubSub.broadcast(
           Tymeslot.PubSub,
           topic(user_id),
           {:availability_changed, user_id}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Availability broadcast failed", reason: reason, user_id: user_id)
        :ok
    end
  end

  @doc """
  Records that what a host offers changed, but not their calendar: their
  weekly hours, or a meeting type's name, length or place. Clears the
  cached availability ranges and keeps the cached calendar events, whose
  window depends only on the host's calendars and their schedules'
  booking windows (`AvailabilityCache.invalidate_ranges_for_user/1`). Takes
  what `changed/1` takes. Anything else, a booking, a calendar or a
  schedule's booking policy, calls `changed/1`.
  """
  @spec offer_changed(integer() | ProfileSchema.t() | AvailabilityScheduleSchema.t() | nil) ::
          :ok
  def offer_changed(nil), do: :ok

  def offer_changed(user_id) when is_integer(user_id),
    do: AvailabilityCache.invalidate_ranges_for_user(user_id)

  def offer_changed(%ProfileSchema{user_id: user_id}), do: offer_changed(user_id)

  def offer_changed(%AvailabilityScheduleSchema{profile_id: profile_id}),
    do: profile_id |> ProfileQueries.user_id_for_profile() |> offer_changed()

  @doc """
  The host's next seven days as the booking page offers them, with the
  calendar's busy blocks; see `Tymeslot.Availability.WeekPreview`.

  Takes `:meeting_type` and `:today`. `{:error, :calendar_unavailable}` when
  the host's calendar could not be read.
  """
  @spec week_preview(ProfileSchema.t(), keyword()) ::
          {:ok, WeekPreview.t()} | {:error, :calendar_unavailable}
  defdelegate week_preview(profile, opts \\ []), to: WeekPreview, as: :build

  @doc """
  The host's week as one window over a set of days, read from their default
  schedule; see `Tymeslot.Availability.WeeklyHours`. `nil` without one.
  """
  @spec weekly_hours(integer()) :: WeeklyHours.t() | nil
  defdelegate weekly_hours(profile_id), to: WeeklyHours, as: :get

  @doc """
  Checks a week before it is written: at least one day, and an end after the
  start.
  """
  @spec validate_weekly_hours(map()) ::
          :ok | {:error, :no_days | :invalid_day | :end_before_start | :invalid_time}
  defdelegate validate_weekly_hours(hours), to: WeeklyHours, as: :validate

  @doc """
  Writes the host's week to their default schedule, all of it or none: the
  chosen days (ISO weekdays) get the one window, every other day is turned
  off. Clears the cached availability once it commits.
  """
  @spec set_weekly_hours(integer(), map()) :: :ok | {:error, WeeklyHours.error()}
  defdelegate set_weekly_hours(profile_id, hours), to: WeeklyHours, as: :set

  @doc """
  Today's date where the host is: in the profile's timezone, or the host
  default for a profile without one (`Tymeslot.Profiles.timezone/1`), read
  from `Tymeslot.Clock`.
  """
  @spec today(ProfileSchema.t() | map() | nil) :: Date.t()
  def today(profile), do: profile |> Profiles.timezone() |> TimeOff.today()
end
