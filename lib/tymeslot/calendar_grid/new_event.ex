defmodule Tymeslot.CalendarGrid.NewEvent do
  @moduledoc """
  Creating an event from the calendar, and caching it so it shows at once
  rather than after the next sync.

  `create/2` runs `EventCreation.run_create_event/1` (the provider write, a
  video room, the guests' invitations and the dropped availability all
  happen there) and then caches the event from what the provider answered:
  the calendar it actually wrote to, the identity it reported, the place,
  free/busy and the guests. Nothing is cached for a create that did not
  reach the calendar; a queued CalDAV create is tagged by the offline queue
  instead.
  """

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.CalendarGrid.SeriesCarry
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @typedoc """
  A create that reached the calendar: the cached row (`nil` only when the
  cache refused a row with incomplete timing), the addresses invited, a
  warning to show beside the success (a Meet link Google did not return),
  and whether the calendar needs reconnecting.
  """
  @type created :: %{
          event: ProviderCalendarEventSchema.t() | nil,
          invited: [String.t()],
          warning: String.t() | nil,
          reauth_required: boolean()
        }

  @type failure :: %{reason: term(), retry: :queued | :not_queued}

  @doc """
  Creates the event `payload` describes for `user_id`. `payload` is the map
  `EventCreation.run_create_event/1` takes (`:creating`, `:start_at`,
  `:end_at`, optionally `:timezone`); its `:user_id` is always `user_id`.
  A `%CreateParams{}` the calendar checked is turned into that payload
  first.
  """
  @spec create(pos_integer(), CreateParams.t() | map()) ::
          {:ok, created()} | {:error, failure()}
  def create(user_id, %CreateParams{} = params),
    do: create(user_id, CreateParams.to_payload(params))

  def create(user_id, payload) when is_integer(user_id) and is_map(payload) do
    with {:ok, result} <-
           payload |> Map.put(:user_id, user_id) |> EventCreation.run_create_event() do
      attrs = row_attrs(result)
      :ok = cache(attrs)

      {:ok,
       %{
         event: cached_row(attrs),
         invited: Enum.map(result.attendees, & &1.email),
         warning: result[:warning],
         reauth_required: result[:reauth_required] == true
       }}
    end
  end

  @doc """
  Inserts a newly created event into the local cache so it appears
  immediately without waiting for the next sync cycle.

  Accepts a map with `:uid`, `:calendar_integration_id`, `:title`,
  `:start_at`, `:end_at`, and optionally `:all_day`. A recurring event's
  video is handed on to the occurrences its first sync caches
  (`SeriesCarry.series_created/1`).

  The row is marked as Tymeslot's own: the organiser just created it here, and
  a move before the first sync reads ownership off this row
  (`Tymeslot.CalendarGrid.EventMove`).
  """
  @spec cache(map()) :: :ok
  def cache(attrs) do
    {:ok, _count} = ProviderCalendarEventQueries.upsert_batch([normalise_cache_attrs(attrs)])
    SeriesCarry.series_created(attrs)
  end

  # What the provider actually wrote, before what was asked for. A CalDAV
  # write falls back to the booking collection when the chosen calendar is
  # not one the integration lists as writable, and filing the row under the
  # request instead showed the event on a calendar it is not on until the
  # next sync corrected it.
  #
  # The provider's identity (`provider_event_id`, `etag`) is the only one the
  # row has until a full sync runs; either may be nil, as a CalDAV server is
  # not obliged to answer a PUT with an ETag.
  defp row_attrs(result) do
    creating = result.creating
    all_day = Map.get(creating, :all_day, false)

    all_day
    |> timing(result.start_at, result.end_at)
    |> Map.merge(%{
      uid: result.uid,
      calendar_integration_id: creating.integration_id,
      provider: result.provider,
      provider_calendar_id:
        result.written_calendar_id || creating[:calendar_id] ||
          result.default_booking_calendar_id || "primary",
      provider_event_id: result.provider_event_id,
      etag: result.etag,
      summary: creating.title,
      description: result.description,
      location: creating[:location],
      transparency: creating[:transparency] || "opaque",
      attendees: Enum.map(result.attendees, &Attendee.new(email: &1.email)),
      all_day: all_day,
      reminders: Map.get(creating, :reminders, []),
      recurrence_rule: Map.get(creating, :recurrence_rule),
      video_link: result.meeting_url,
      video_integration_id: creating[:video_integration_id]
    })
  end

  # All-day events store `start_date`/`end_date` (the cache row leaves
  # `start_at`/`end_at` null); timed events store `start_at`/`end_at`.
  defp timing(true, %Date{} = start_date, %Date{} = end_date),
    do: %{start_date: start_date, end_date: end_date}

  defp timing(_all_day, start_at, end_at), do: %{start_at: start_at, end_at: end_at}

  defp cached_row(attrs) do
    case ProviderCalendarEventQueries.get_by_uid(attrs.calendar_integration_id, attrs.uid) do
      {:ok, row} -> row
      {:error, :not_found} -> nil
    end
  end

  # The cached events schema stores start/end/synced_at as :utc_datetime_usec
  # and requires synced_at NOT NULL. The create flow builds datetimes at
  # second precision and doesn't always supply synced_at; it is writing what
  # it just committed, so "now" is the correct sync timestamp. synced_at is
  # upcast unconditionally so a caller-supplied second-precision value does not
  # fail Ecto's :utc_datetime_usec check. The clock is read through
  # `Tymeslot.Clock` (`CredoChecks.ClockUsage` covers this directory).
  defp normalise_cache_attrs(attrs) do
    now = Clock.utc_now()

    attrs
    |> Map.put(:created_by_tymeslot, true)
    |> Map.update(:start_at, nil, &to_usec/1)
    |> Map.update(:end_at, nil, &to_usec/1)
    |> Map.put_new(:synced_at, now)
    |> Map.update!(:synced_at, &to_usec/1)
  end

  defp to_usec(%DateTime{microsecond: {_value, 6}} = dt), do: dt
  defp to_usec(%DateTime{} = dt), do: %{dt | microsecond: {elem(dt.microsecond, 0), 6}}
  defp to_usec(other), do: other
end
