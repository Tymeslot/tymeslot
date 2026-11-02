defmodule Tymeslot.Meetings.AttendeeNotifications.SeriesEntries do
  @moduledoc """
  The entries attendee emails about a recurring series put in its guests'
  calendars, recorded apart from the series' cached rows.

  Which occurrences a guest was emailed about on their own could once be
  told only from their cached rows' notified state and revision
  (`Tymeslot.Meetings.AttendeeNotifications.SeriesIdentity`). A write to a
  whole series drops those rows and a sync brings them back blank
  (`Tymeslot.CalendarGrid.SeriesEdit`), so an email about every occurrence
  sent after it would neither move those entries nor, on a later
  cancellation, remove them. Each entry an email sends is recorded here
  instead, against the series as its provider addresses it as a whole
  (`Tymeslot.CalendarGrid.Occurrence.series_address/1`), which the write
  leaves as it was.

  The record keeps the UID the guest holds, never one looked up again: a
  Google edit of every occurrence that moves them gives each a new original
  start, and so a new uid, once synced.

  Only an occurrence of a series is recorded; a single event, or an event
  whose series cannot be addressed, is not.
  """

  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Meetings.AttendeeNotifications.SeriesEntryQueries
  alias Tymeslot.Meetings.AttendeeNotifications.SeriesEntrySchema
  alias Tymeslot.Meetings.AttendeeNotifications.SeriesIdentity

  @doc """
  Records `entries`, each sent at its `:sequence`, as entries of the series
  `event` (a cached row, or the map of one) belongs to.
  """
  @spec record(map(), [SeriesIdentity.entry()]) :: :ok
  def record(event, entries) do
    with {:ok, integration_id, address} <- address(event) do
      SeriesEntryQueries.put_all(integration_id, address, Enum.flat_map(entries, &attrs/1))
    end

    :ok
  end

  @doc """
  The entries recorded for the series `event` belongs to, each with the
  SEQUENCE it was last sent at as `:sent_sequence`.
  """
  @spec recorded(map()) :: [SeriesIdentity.entry()]
  def recorded(event) do
    case address(event) do
      {:ok, integration_id, address} ->
        integration_id |> SeriesEntryQueries.list(address) |> Enum.map(&to_entry/1)

      :none ->
        []
    end
  end

  @doc """
  The SEQUENCE the entry `uid` of the series `event` belongs to was last
  sent at, nil when none is recorded.
  """
  @spec sent_sequence(map(), String.t() | nil) :: non_neg_integer() | nil
  def sent_sequence(_event, nil), do: nil

  def sent_sequence(event, uid) do
    Enum.find_value(recorded(event), fn
      %{uid: ^uid, sent_sequence: sequence} -> sequence
      _other -> nil
    end)
  end

  @doc "Forgets the entry `uid` of the series `event` belongs to, once cancelled."
  @spec forget(map(), String.t() | nil) :: :ok
  def forget(_event, nil), do: :ok

  def forget(event, uid) do
    with {:ok, integration_id, address} <- address(event),
         do: SeriesEntryQueries.delete(integration_id, address, uid)

    :ok
  end

  @doc "Forgets every entry of the series `event` belongs to, once it is cancelled."
  @spec forget_series(map()) :: :ok
  def forget_series(event) do
    with {:ok, integration_id, address} <- address(event),
         do: SeriesEntryQueries.delete_all(integration_id, address)

    :ok
  end

  defp address(%{calendar_integration_id: integration_id} = event)
       when is_integer(integration_id) do
    case Occurrence.series_address(event) do
      {:ok, {kind, id}} -> {:ok, integration_id, "#{kind}:#{id}"}
      {:error, _not_a_series} -> :none
    end
  end

  defp address(_event), do: :none

  defp attrs(%{uid: uid, start: %Date{} = from, end: %Date{} = to} = entry),
    do: [%{entry_uid: uid, start_date: from, end_date: to, sent_sequence: sequence(entry)}]

  defp attrs(%{uid: uid, start: %DateTime{} = from, end: %DateTime{} = to} = entry),
    do: [%{entry_uid: uid, start_at: from, end_at: to, sent_sequence: sequence(entry)}]

  defp attrs(_untimed), do: []

  defp sequence(entry), do: Map.get(entry, :sequence) || 0

  defp to_entry(%SeriesEntrySchema{start_date: %Date{} = from, end_date: %Date{} = to} = row),
    do: %{uid: row.entry_uid, start: from, end: to, sent_sequence: row.sent_sequence}

  defp to_entry(%SeriesEntrySchema{} = row),
    do: %{
      uid: row.entry_uid,
      start: row.start_at,
      end: row.end_at,
      sent_sequence: row.sent_sequence
    }
end
