defmodule Tymeslot.Availability.Offer.HostCalendar do
  @moduledoc """
  How `Tymeslot.Availability.Offer` reads the host's calendar events.

  The provider fetch behind this is window-shaped, not month-shaped:
  `Events.get_calendar_events/3` ignores the date it is given and always asks
  for `today .. today + advance_booking_days`. Folding it under a key built
  from the 42-day *display* range would therefore store the same event list
  once per rendered month and guarantee a miss for anything that moves the
  calendar, worst of all the next-available forward search, which re-enters
  `days_in_range/4` once per hop and would otherwise buy an identical round
  trip to the host's calendar each time, on exactly the fully booked hosts
  the search exists to help.

  So the events get their own entry (`booking_window/2`), keyed on the user
  alone because that is the fetch's entire input. The folded map keeps its
  display-range key: the fold is what actually differs between hops. A date
  click reads the same entry, so picking a day after the month view costs no
  provider round trip either. Its slots can therefore be up to the cache's
  lifetime old; the booking submit re-reads the calendars uncached
  (`Tymeslot.Bookings.CalendarCheck`), and that read is what refuses a slot
  taken in the meantime.

  Errors stay uncached, for the reason `get_or_compute_events/2` exists at
  all: a timed-out calendar must be retried on the next request, not pinned
  empty for the TTL. `Tymeslot.Availability.changed/1` drops this entry with
  the folded maps, so a calendar sync cannot leave the two disagreeing about
  how fresh they are.

  A range (`for_range/3`) is read fresh, as the booking page's week view
  needs, unless the caller asks for the cached entry: with `:cached`, as the
  calendar's bookable layer does so that it agrees with the day and month
  views, or with `cached_calendar: true` on the request, as the setup preview
  of the host's week does, so that reloading it costs no provider round trip.

  Either way the events come back with the bookability rule applied
  (`Tymeslot.Availability.Bookability`): the host's "Treat as Busy" or
  "Treat as Free" on an all-day event wins over its calendar. The cached entry is stored with
  the rule already applied; an override and a calendar's settings both call
  `Tymeslot.Availability.changed/1`, which drops it.
  """

  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents

  @doc "The host's events across the booking window, through the cache."
  @spec booking_window(map(), Date.t()) :: {:ok, list()} | {:error, any()}
  def booking_window(%{profile: %{user_id: user_id}} = request, date) do
    AvailabilityCache.get_or_compute_events(
      AvailabilityCache.booking_window_events_key(user_id),
      fn ->
        with {:ok, events} <- fresh(request, date) do
          {:ok, Bookability.apply_to_window(events, user_id)}
        end
      end
    )
  end

  @doc """
  The host's events for a read of `first_date..last_date`: fresh (`source`
  `:fresh`, the default), or the cached booking-window entry when `source` is
  `:cached` or the request sets `cached_calendar: true`.
  """
  @spec for_range(map(), {Date.t(), Date.t()}, :fresh | :cached) ::
          {:ok, list()} | {:error, any()}
  def for_range(request, dates, source \\ :fresh)

  def for_range(%{cached_calendar: true} = request, {first_date, _last_date}, _source),
    do: booking_window(request, first_date)

  def for_range(request, {first_date, _last_date}, :cached),
    do: booking_window(request, first_date)

  def for_range(
        %{profile: %{user_id: user_id}} = request,
        {first_date, _last_date} = dates,
        :fresh
      ) do
    with {:ok, events} <- fresh(request, first_date) do
      {:ok, Bookability.apply_to_dates(events, user_id, dates)}
    end
  end

  @doc """
  The context map the calendar fetch reads. Its contract names this one key
  only, so the demo provider's extra keys stay out of it.
  """
  @spec context(map()) :: map()
  def context(%{profile: profile}), do: %{organizer_profile: profile}

  defp fresh(%{profile: %{user_id: user_id}} = request, date),
    do: CalendarEvents.get_calendar_events_from_context(date, user_id, context(request))
end
