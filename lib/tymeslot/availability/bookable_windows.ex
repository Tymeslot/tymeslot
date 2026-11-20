defmodule Tymeslot.Availability.BookableWindows do
  @moduledoc """
  The times an organiser's own calendar shows as bookable for one meeting
  type, and the first of them ahead.

  A window is the union of the meetings the booking page offers: every start
  `Tymeslot.Availability.Offer.starts_in_range/5` lists, held for the meeting
  type's duration, merged where they touch or overlap. The booking page labels
  the same starts, so a time inside a window is a time a guest can book, and
  nothing a guest can book lies outside one. A free stretch too short for the
  meeting, or off the slot grid, is in no window. The starts are read with
  the cached booking-window events (`events: :cached`), the read the booking
  page's day and month views share, so a window is never fresher or staler
  than the page.

  Dates are the organiser's (their profile's timezone); windows come back in
  UTC. The meeting type must be the user's, active and not archived.
  """

  alias Tymeslot.Availability.Intervals
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils

  # The longest range `Offer.starts_in_range/5` answers, which is also the
  # step `next/3` searches in.
  @step_days 42
  @utc "Etc/UTC"

  @type window :: %{start_at: DateTime.t(), end_at: DateTime.t()}

  @doc """
  The bookable windows over `from..to` (organiser dates, inclusive, at most
  42 days), in UTC and in order.

  Returns `{:error, :not_found}` for a meeting type that is not the user's,
  is archived or inactive, `{:error, :invalid_range}` when `to` is before
  `from`, `{:error, :range_too_long}` past 42 days, and the calendar's
  reason when the organiser's calendar cannot be read.
  """
  @spec windows(pos_integer(), pos_integer(), Date.t(), Date.t()) ::
          {:ok, [window()]}
          | {:error, :not_found | :invalid_range | :range_too_long | term()}
  def windows(user_id, meeting_type_id, %Date{} = from, %Date{} = to) do
    with {:ok, request} <- request(user_id, meeting_type_id),
         {:ok, starts} <-
           Offer.starts_in_range(request, from, to, duration(request), events: :cached) do
      {:ok, merge(starts, duration(request))}
    end
  end

  @doc """
  The first bookable start at or after `after_at`, in UTC, or `nil` when
  there is none before the end of the meeting type's booking window.
  Searched in 42-day steps; the calendar is read once, from the cache the
  booking page shares.
  """
  @spec next(pos_integer(), pos_integer(), DateTime.t()) ::
          {:ok, DateTime.t() | nil} | {:error, :not_found | term()}
  def next(user_id, meeting_type_id, %DateTime{} = after_at) do
    with {:ok, request} <- request(user_id, meeting_type_id) do
      timezone = request.user_timezone
      today = timezone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()

      first =
        Enum.max([after_at |> DateTime.shift_zone!(timezone) |> DateTime.to_date(), today], Date)

      last = Date.add(today, advance_days(request))

      search(request, first, last, after_at)
    end
  end

  defp search(request, first, last, after_at) do
    if Date.after?(first, last) do
      {:ok, nil}
    else
      chunk_end = Enum.min([Date.add(first, @step_days - 1), last], Date)

      with {:ok, starts} <-
             Offer.starts_in_range(request, first, chunk_end, duration(request), events: :cached) do
        case first_from(starts, after_at) do
          nil -> search(request, Date.add(chunk_end, 1), last, after_at)
          start -> {:ok, DateTime.shift_zone!(start, @utc)}
        end
      end
    end
  end

  defp first_from(starts, after_at) do
    starts
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(DateTime.compare(&1, after_at) != :lt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  defp merge(starts, duration) do
    starts
    |> Map.values()
    |> List.flatten()
    |> Enum.map(fn start ->
      start = DateTime.shift_zone!(start, @utc)
      {start, DateTime.add(start, duration, :minute)}
    end)
    |> Intervals.merge()
    |> Enum.map(fn {start_at, end_at} -> %{start_at: start_at, end_at: end_at} end)
  end

  # The organiser's view of their own page: the booker's timezone is theirs.
  defp request(user_id, meeting_type_id)
       when is_integer(user_id) and is_integer(meeting_type_id) do
    with %MeetingTypeSchema{is_active: true, is_archived: false} = meeting_type <-
           MeetingTypes.get_meeting_type(meeting_type_id, user_id),
         {:ok, profile} <- Profiles.get_profile_by_user_id(user_id) do
      {:ok,
       %{
         profile: profile,
         user_timezone: Profiles.timezone(profile),
         meeting_type: meeting_type,
         organiser_view: true
       }}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp request(_user_id, _meeting_type_id), do: {:error, :not_found}

  defp duration(%{meeting_type: meeting_type}), do: Offer.duration_minutes(meeting_type, nil)

  defp advance_days(%{meeting_type: meeting_type, profile: profile}) do
    meeting_type
    |> Schedules.resolve_for(profile)
    |> Schedules.policy(:advance_booking_days)
  end
end
