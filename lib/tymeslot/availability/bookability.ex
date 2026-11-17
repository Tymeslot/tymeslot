defmodule Tymeslot.Availability.Bookability do
  @moduledoc """
  Whether a calendar event stops guests booking the time it covers, and the
  organiser's say over that.

  The rule: an override the organiser set on an all-day event ("Treat as
  Busy" or "Treat as Free") wins; without one, an event blocks exactly when
  `CalendarEvent.blocking?/1` says, after a subscription that counts every
  event as busy (`all_events_busy`) has made it busy. Whether the calendar
  takes writes plays no part: a free day on a colleague's shared calendar
  stays free unless the organiser says otherwise.

  Only calendars that block availability are read at all
  (`AvailabilityView`), so a calendar set to show only never blocks,
  whatever this rule says.

  The slot engine applies the rule through `apply_to_window/2` (the booking
  page's cached booking-window read, which `bookable_windows` shares),
  `apply_to_dates/3` (the guest week view's fresh read) and `apply_to_busy/3`
  (the submit's own re-read and the poll conflict hint), so the page, the
  week view, the calendar and the submit agree; the free/busy feed reads the
  cache and asks `busy_for_bookings?/2` directly. The live fetch carries no
  calendar on its events, so overrides are matched on the user's cached
  all-day rows: one the organiser treats as busy but its calendar marks
  free is added to the busy set, and a live event one treats as free is
  dropped from it. A user with no overrides gets the events back as they
  are. Overrides on timed events are stored but do not reach bookings; the
  calendar offers the choice on all-day events only.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.BookabilityOverrideQueries
  alias Tymeslot.Availability.Events
  alias Tymeslot.Availability.Reach
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.AvailabilityView
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Validation.Constraints

  @utc "Etc/UTC"

  @typedoc "The user's choices, by `{calendar_integration_id, uid}`."
  @type overrides :: %{{integer(), String.t()} => boolean()}

  @doc """
  Records that the event `uid` of the user's integration `integration_id`
  is busy (`true`) or free (`false`) for bookings, replacing any earlier
  choice. `{:error, :not_found}` for an integration the user does not own.
  """
  @spec set(integer(), integer(), String.t(), boolean()) ::
          :ok | {:error, :not_found | Ecto.Changeset.t()}
  def set(user_id, integration_id, uid, busy?) when is_boolean(busy?) do
    if CalendarIntegrationQueries.owned_by?(integration_id, user_id) do
      with {:ok, _override} <-
             BookabilityOverrideQueries.upsert(user_id, integration_id, uid, busy?) do
        Availability.changed(user_id)
      end
    else
      {:error, :not_found}
    end
  end

  @doc "Puts the event back under the rule."
  @spec clear(integer(), integer(), String.t()) :: :ok | {:error, :not_found}
  def clear(user_id, integration_id, uid) do
    if CalendarIntegrationQueries.owned_by?(integration_id, user_id) do
      :ok = BookabilityOverrideQueries.delete(user_id, integration_id, uid)
      Availability.changed(user_id)
    else
      {:error, :not_found}
    end
  end

  @doc "The user's choices, keyed by `{calendar_integration_id, uid}`."
  @spec for_user(integer()) :: overrides()
  def for_user(user_id) do
    user_id
    |> BookabilityOverrideQueries.list_for_user()
    |> Map.new(&{{&1.calendar_integration_id, &1.provider_uid}, &1.busy})
  end

  @doc """
  Whether `event` (a cached event, carrying its integration and uid, with
  its subscription's `all_events_busy` already applied) stops guests booking
  its time: the organiser's override on an all-day event, otherwise
  `CalendarEvent.blocking?/1`.
  """
  @spec busy_for_bookings?(CalendarEvent.t(), overrides()) :: boolean()
  def busy_for_bookings?(%CalendarEvent{all_day: true} = event, overrides) do
    Map.get_lazy(overrides, {event.calendar_integration_id, event.uid}, fn ->
      CalendarEvent.blocking?(event)
    end)
  end

  def busy_for_bookings?(%CalendarEvent{} = event, _overrides), do: CalendarEvent.blocking?(event)

  @doc """
  `apply_to_busy/3` over every date a booking-window read can cover: from
  the UTC padding before today to the longest booking window any schedule
  may have, plus a meeting's reach. One cached event list then serves
  every schedule of the host.
  """
  @spec apply_to_window([map()], integer()) :: [map()]
  def apply_to_window(events, user_id) do
    today = Clock.utc_today()
    padding = Reach.utc_padding_days()
    reach = Constraints.advance_booking_days_range().last + Reach.meeting_days() + padding

    apply_to_busy(events, user_id, {Date.add(today, -padding), Date.add(today, reach)})
  end

  @doc """
  `apply_to_busy/3` over the booker dates `first..last` and the owner dates
  a slot listed under them can reach (`Reach.owner_days/0` either side): the
  guest week view's fresh read, which covers a week rather than the whole
  booking window. The cached rows are dated in the owner's zone, so the pad
  is the owner reach rather than the UTC one.
  """
  @spec apply_to_dates([map()], integer(), {Date.t(), Date.t()}) :: [map()]
  def apply_to_dates(events, user_id, {%Date{} = first, %Date{} = last}) do
    days = Reach.owner_days()

    apply_to_busy(events, user_id, {Date.add(first, -days), Date.add(last, days)})
  end

  @doc """
  The calendar `events` the slot engine weighs, with the organiser's
  overrides applied over the dates `from..to`: the user's cached all-day
  events treated as busy but marked free by their calendar are added, and
  live events treated as free are dropped. Events of a user with no
  calendar or no overrides come back unchanged.
  """
  @spec apply_to_busy([map()], integer(), {Date.t(), Date.t()}) :: [map()]
  def apply_to_busy(events, user_id, {%Date{}, %Date{}} = range) do
    with overrides when overrides != %{} <- for_user(user_id),
         [_first | _rest] = integrations <-
           CalendarIntegrationQueries.list_active_for_user(user_id) do
      adjust(events, integrations, overrides, range)
    else
      _nothing_to_apply -> events
    end
  end

  defp adjust(events, integrations, overrides, range) do
    by_id = Map.new(integrations, &{&1.id, &1})

    {added, freed} =
      integrations
      |> Enum.map(& &1.id)
      |> CalendarEventQueries.all_day_in_range(range, AvailabilityView.rules(integrations))
      |> Enum.reduce({[], []}, fn row, {added, freed} ->
        row = as_presented(row, Map.fetch!(by_id, row.calendar_integration_id))

        case {busy_for_bookings?(row, overrides), CalendarEvent.blocking?(row)} do
          {true, false} -> {[busy_period(row) | added], freed}
          {false, true} -> {added, [row | freed]}
          _agrees -> {added, freed}
        end
      end)

    events
    |> Enum.reject(fn event -> Enum.any?(freed, &same_event?(event, &1)) end)
    |> Enum.concat(added)
  end

  @doc """
  The event as availability reads it: a subscription that counts every
  event as busy (`all_events_busy`) hands out its events busy, so a free
  cached row is a busy one.
  """
  @spec as_presented(CalendarEvent.t(), map() | nil) :: CalendarEvent.t()
  def as_presented(event, %{all_events_busy: true}), do: CalendarEvent.as_busy(event)
  def as_presented(event, _integration), do: event

  # The plain shape the live fetch returns, with neither `status` nor
  # `transparency`, so `CalendarEvent.blocking?/1` counts it, and the dates
  # `Events.to_interval/2` reads as the owner's whole day.
  defp busy_period(row) do
    %{
      uid: row.uid,
      provider_event_id: row.provider_event_id,
      all_day: true,
      start_time: row.start_date,
      end_time: row.end_date
    }
  end

  # A live event is the cached row when one of the identifiers its provider
  # family shares with the cache matches (Google and Outlook hand out their
  # own id live and cache under the iCal uid; a CalDAV occurrence is cached
  # as `<UID>_<suffix>` at its series' href, which the live event carries)
  # and the two cover the same time.
  defp same_event?(event, row) do
    ids =
      for key <- [:uid, :ical_uid, :provider_event_id, :href],
          id = Map.get(event, key),
          do: id

    Enum.any?(ids, &(&1 in [row.uid, row.provider_event_id])) and overlapping?(event, row)
  end

  defp overlapping?(event, row) do
    with {:ok, {event_start, event_end}} <- Events.to_interval(event, @utc),
         {:ok, {row_start, row_end}} <- Events.to_interval(row, @utc) do
      DateTime.compare(event_start, row_end) == :lt and
        DateTime.compare(row_start, event_end) == :lt
    else
      :error -> false
    end
  end
end
