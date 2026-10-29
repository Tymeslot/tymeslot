defmodule Tymeslot.Meetings.AttendeeNotifications.SeriesIdentity do
  @moduledoc """
  Which entry in a guest's calendar an attendee email about an occurrence of
  a recurring event changes.

  Every attachment is a single event (`Tymeslot.Emails.Shared.CalendarEventContent.ics_details/2`),
  so a guest's calendar holds one entry per occurrence it was emailed about,
  each under its own UID. The invitation sent when the grid created the
  series is the exception: it describes the series' first occurrence under
  the UID the provider reported for the series as a whole
  (`Tymeslot.Integrations.Calendar.CreatedEvent.cache_uid/1`), while the
  cache files that occurrence, like every other, under a uid of its own. An
  email about it under the occurrence's uid would add a second entry beside
  the invitation's instead of changing it.

  So the series' first occurrence is addressed by the series' UID
  (`entry_uid/1`), and every other occurrence by its own. The series' UID is:

    * Google: the series' `iCalUID`, which the occurrence's raw event
      carries.
    * Outlook: the master's `iCalUId`, stored with its repeat rule
      (`Tymeslot.Integrations.Calendar.SeriesRules.ical_uid/2`), since every
      occurrence has one of its own.
    * CalDAV: the resource's UID, kept in the occurrence's metadata.

  An email about the whole series sent from another occurrence changes the
  invitation's entry too (`series_entry/2`): a cancellation of every
  occurrence removes it, and an edit of all of them moves it as far as it
  moved the occurrence.

  A single event, a master's own row, an Exchange item, or an occurrence
  whose series' UID or first start cannot be told keeps its own uid.
  """

  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.SeriesStart
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Utils.MapKeys

  @typedoc """
  A further entry an email's attachment changes: its UID and timing, a
  `Date` pair (end exclusive) for an all-day series, UTC instants otherwise.
  """
  @type entry :: %{
          uid: String.t(),
          start: Date.t() | DateTime.t(),
          end: Date.t() | DateTime.t()
        }

  # The original start Google ends an occurrence's uid with.
  @google_stamp ~r/\A(.+)_\d{8}(?:T\d{6}Z)?\z/

  @doc """
  The UID of the guest's entry for `event`: its series' UID for the series'
  first occurrence, its own uid otherwise. `event` is the cached row, or a
  map naming its integration and uid, which is read back.
  """
  @spec entry_uid(map()) :: String.t() | nil
  def entry_uid(event) do
    row = row(event)

    case first_occurrence(row) do
      {:first, series_uid, _first} -> series_uid
      _other -> Map.get(event, :uid)
    end
  end

  @doc """
  The invitation's entry for the series `original` (the occurrence an email
  about every occurrence was sent from, as it was) belongs to, when that is
  not `original`'s own entry already. `updated` is that occurrence as an
  edit of all of them left it, which moves the entry by as much as it moved
  the occurrence; nil for a cancellation, which leaves it where it was.
  """
  @spec series_entry(map(), map() | nil) :: entry() | nil
  def series_entry(original, updated \\ nil) do
    row = row(original)
    now = updated || original

    with {:other, series_uid, first} <- first_occurrence(row),
         {:ok, moved_by} <- moved_by(original, now),
         {:ok, duration} <- duration(now) do
      start = shift(first, moved_by)
      %{uid: series_uid, start: start, end: shift(start, duration)}
    else
      _none -> nil
    end
  end

  @doc "`entries` as an email job's JSON arg."
  @spec to_arg([entry()]) :: [%{String.t() => String.t()}]
  def to_arg(entries) do
    Enum.map(entries, fn entry ->
      %{"uid" => entry.uid, "start" => encode(entry.start), "end" => encode(entry.end)}
    end)
  end

  @doc "The entries an email job's arg names, leaving out any unreadable."
  @spec from_arg(term()) :: [entry()]
  def from_arg(arg) when is_list(arg) do
    Enum.flat_map(arg, fn
      %{"uid" => uid, "start" => start, "end" => ending} when is_binary(uid) ->
        with %{} = start <- decode(start),
             %{} = ending <- decode(ending),
             do: [%{uid: uid, start: start, end: ending}],
             else: (_unreadable -> [])

      _unreadable ->
        []
    end)
  end

  def from_arg(_none), do: []

  defp encode(%Date{} = date), do: Date.to_iso8601(date)
  defp encode(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp decode(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} ->
        at

      {:error, _not_an_instant} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> date
          {:error, _unreadable} -> nil
        end
    end
  end

  defp decode(_value), do: nil

  defp row(%ProviderCalendarEventSchema{} = row), do: row
  defp row(event), do: Occurrence.cached_row(event)

  # Whether `row` is the first occurrence of a series whose UID is known
  # (`{:first, uid, first_start}`) or another one of it (`{:other, ...}`).
  defp first_occurrence(row) do
    with series_uid when is_binary(series_uid) <- series_uid(row),
         %{} = first <- SeriesStart.of_cached(row),
         %{} = slot <- SeriesStart.slot_of_cached(row) do
      if same_start?(slot, first),
        do: {:first, series_uid, first},
        else: {:other, series_uid, first}
    else
      _not_an_occurrence -> :none
    end
  end

  defp same_start?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  defp same_start?(%Date{} = a, %Date{} = b), do: Date.compare(a, b) == :eq
  defp same_start?(_a, _b), do: false

  # Only an occurrence names a series apart from itself: a single event or a
  # master's own row is filed under its own UID.
  defp series_uid(row) do
    case to_string(Map.get(row, :provider)) do
      "google" -> google_series_uid(row)
      "outlook" -> outlook_series_uid(row)
      _caldav_or_other -> caldav_series_uid(row)
    end
  end

  defp google_series_uid(%{recurring_event_id: master_id} = row)
       when is_binary(master_id) and master_id != "" do
    MapKeys.get_binary(Map.get(row, :provider_metadata), :iCalUID) || unstamped(row.uid)
  end

  defp google_series_uid(_row), do: nil

  defp unstamped(uid) when is_binary(uid) do
    case Regex.run(@google_stamp, uid, capture: :all_but_first) do
      [series_uid] -> series_uid
      nil -> nil
    end
  end

  defp unstamped(_uid), do: nil

  defp outlook_series_uid(%{recurring_event_id: master_id, calendar_integration_id: id})
       when is_binary(master_id) and master_id != "" and is_integer(id),
       do: SeriesRules.ical_uid(id, master_id)

  defp outlook_series_uid(_row), do: nil

  # An expanded occurrence is filed under the resource's UID and its key; the
  # resource's own row keeps the bare UID.
  defp caldav_series_uid(row) do
    with :caldav <- Occurrence.series_family(row),
         {:ok, _key} <- Occurrence.occurrence_key(row) do
      MapKeys.get_binary(Map.get(row, :provider_metadata), :uid)
    else
      _not_an_occurrence -> nil
    end
  end

  # An all-day series moves by whole days, a timed one by seconds.
  defp moved_by(%{all_day: true, start_date: %Date{} = from}, %{start_date: %Date{} = to}),
    do: {:ok, {:days, Date.diff(to, from)}}

  defp moved_by(from, to) do
    with %DateTime{} = from_at <- start_at(from),
         %DateTime{} = to_at <- start_at(to) do
      {:ok, {:seconds, DateTime.diff(to_at, from_at)}}
    else
      _untimed -> :error
    end
  end

  defp duration(%{all_day: true, start_date: %Date{} = from, end_date: %Date{} = to}),
    do: {:ok, {:days, Date.diff(to, from)}}

  defp duration(event) do
    with %DateTime{} = from <- start_at(event),
         %DateTime{} = to <- Map.get(event, :end_at) || Map.get(event, :end_time) do
      {:ok, {:seconds, DateTime.diff(to, from)}}
    else
      _untimed -> :error
    end
  end

  defp start_at(event), do: Map.get(event, :start_at) || Map.get(event, :start_time)

  # The first start takes the series' type, which an edit between a timed
  # and an all-day series no longer matches; such an entry is moved by the
  # whole days or seconds the other type gives.
  defp shift(%Date{} = date, {:days, days}), do: Date.add(date, days)
  defp shift(%Date{} = date, {:seconds, seconds}), do: Date.add(date, div(seconds, 86_400))
  defp shift(%DateTime{} = at, {:seconds, seconds}), do: DateTime.add(at, seconds)
  defp shift(%DateTime{} = at, {:days, days}), do: DateTime.add(at, days * 86_400)
end
