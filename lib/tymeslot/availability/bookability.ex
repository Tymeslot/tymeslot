defmodule Tymeslot.Availability.Bookability do
  @moduledoc """
  Whether a calendar event stops guests booking the time it covers, and the
  organiser's say over that.

  The rule:

    * an override the organiser set ("Treat as Busy" or "Treat as Free")
      wins;
    * without one, an all-day event on a read-only calendar counts as Busy
      even when its calendar marks it free: holiday feeds mark every day
      free, and a public holiday is not a day to take bookings on. A
      cancelled one still does not count;
    * everything else counts exactly when `CalendarEvent.blocking?/1` says.

  Only calendars that block availability are read at all
  (`AvailabilityView`), so a calendar set to show only never blocks,
  whatever this rule says.

  The slot engine applies the rule through `apply_to_window/2` (the booking
  page's cached booking-window read, which `bookable_windows` shares) and
  `apply_to_busy/3` (the submit's own re-read), so the page, the calendar
  and the submit agree. The live fetch carries no calendar on its events,
  so the rule is decided on the user's cached all-day rows: one the rule
  makes busy but its calendar marks free is added to the busy set, and a
  live event an override frees is dropped from it. Overrides on timed
  events are stored but do not reach bookings; the calendar offers the
  choice on all-day events only.
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
  alias Tymeslot.Integrations.Calendar.Selection
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
  Whether `event` (a cached event, carrying its integration and uid) stops
  guests booking its time. `read_only?` is whether its calendar takes no
  writes (`read_only?/2`).
  """
  @spec busy_for_bookings?(CalendarEvent.t(), boolean(), overrides()) :: boolean()
  def busy_for_bookings?(%CalendarEvent{} = event, read_only?, overrides) do
    case Map.fetch(overrides, {event.calendar_integration_id, event.uid}) do
      {:ok, busy?} -> busy?
      :error -> default_busy?(event, read_only?)
    end
  end

  defp default_busy?(%CalendarEvent{all_day: true} = event, true),
    do: event |> CalendarEvent.as_busy() |> CalendarEvent.blocking?()

  defp default_busy?(event, _read_only?), do: CalendarEvent.blocking?(event)

  @doc """
  Whether a cached event sits on a calendar that takes no writes: a
  subscribed feed, or a calendar its provider reports read-only. The rule
  the edit guard uses (`Selection.event_writable?/2`).
  """
  @spec read_only?(CalendarEvent.t(), map()) :: boolean()
  def read_only?(event, integration), do: not Selection.event_writable?(event, integration)

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
  The calendar `events` the slot engine weighs, with the rule applied over
  the dates `from..to`: the user's cached all-day events the rule makes busy
  but their calendar marks free are added, and live events an override
  frees are dropped. Events of a user with no calendar come back unchanged.
  """
  @spec apply_to_busy([map()], integer(), {Date.t(), Date.t()}) :: [map()]
  def apply_to_busy(events, user_id, {%Date{}, %Date{}} = range) do
    case CalendarIntegrationQueries.list_active_for_user(user_id) do
      [] -> events
      integrations -> adjust(events, integrations, for_user(user_id), range)
    end
  end

  defp adjust(events, integrations, overrides, range) do
    by_id = Map.new(integrations, &{&1.id, &1})

    {added, freed} =
      integrations
      |> Enum.map(& &1.id)
      |> CalendarEventQueries.all_day_in_range(range, AvailabilityView.rules(integrations))
      |> Enum.reduce({[], []}, fn row, {added, freed} ->
        read_only? = read_only?(row, Map.fetch!(by_id, row.calendar_integration_id))

        case {busy_for_bookings?(row, read_only?, overrides), CalendarEvent.blocking?(row)} do
          {true, false} -> {[busy_period(row) | added], freed}
          {false, true} -> {added, [row | freed]}
          _agrees -> {added, freed}
        end
      end)

    events
    |> Enum.reject(fn event -> Enum.any?(freed, &same_event?(event, &1)) end)
    |> Enum.concat(added)
  end

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
  # own id live and cache under the iCal uid) and the two cover the same time.
  defp same_event?(event, row) do
    ids = for key <- [:uid, :ical_uid, :provider_event_id], id = Map.get(event, key), do: id

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
