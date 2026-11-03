defmodule Tymeslot.Meetings.AttendeeNotifications.SeriesEntryQueries do
  @moduledoc """
  Data access for `attendee_series_entries`: the entries attendee emails put
  in guests' calendars for each recurring series.
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.AttendeeNotifications.SeriesEntrySchema
  alias Tymeslot.Repo

  @doc "Every entry recorded for the series `address` of the integration."
  @spec list(integer(), String.t()) :: [SeriesEntrySchema.t()]
  def list(integration_id, address) do
    integration_id
    |> series(address)
    |> order_by([e], asc: e.id)
    |> Repo.all()
  end

  @doc """
  Records the entries in `attrs` for the series `address` of the
  integration, each replacing the timing recorded for its UID. The SEQUENCE
  recorded only ever rises: the guests who already hold the entry keep the
  highest revision they were sent, whatever a later email to a newcomer
  went out at.
  """
  @spec put_all(integer(), String.t(), [map()]) :: :ok
  def put_all(_integration_id, _address, []), do: :ok

  def put_all(integration_id, address, attrs) do
    Repo.transaction(fn ->
      Enum.each(attrs, fn entry ->
        %SeriesEntrySchema{}
        |> SeriesEntrySchema.changeset(
          Map.merge(entry, %{calendar_integration_id: integration_id, series_address: address})
        )
        |> Repo.insert!(
          on_conflict: keep_highest_sequence(),
          conflict_target: [:calendar_integration_id, :series_address, :entry_uid]
        )
      end)
    end)

    :ok
  end

  @doc "Forgets the entry `uid` of the series `address`."
  @spec delete(integer(), String.t(), String.t()) :: :ok
  def delete(integration_id, address, uid) do
    integration_id
    |> series(address)
    |> where([e], e.entry_uid == ^uid)
    |> Repo.delete_all()

    :ok
  end

  @doc "Forgets every entry of the series `address`."
  @spec delete_all(integer(), String.t()) :: :ok
  def delete_all(integration_id, address) do
    integration_id
    |> series(address)
    |> Repo.delete_all()

    :ok
  end

  defp series(integration_id, address) do
    from(e in SeriesEntrySchema,
      where: e.calendar_integration_id == ^integration_id and e.series_address == ^address
    )
  end

  @doc """
  Marks every entry of the series `address` as written now, which keeps
  the series from `delete_stale/1` for as long as a recent email would.
  """
  @spec touch_all(integer(), String.t()) :: :ok
  def touch_all(integration_id, address) do
    now = DateTime.utc_now(:second)

    integration_id
    |> series(address)
    |> Repo.update_all(set: [updated_at: now])

    :ok
  end

  @doc """
  Forgets every series whose cache holds no occurrence any more and none of
  whose recorded entries ends, or was written, on or after `cutoff`: one
  deleted at its provider, or ended, long enough ago that no sync reaches
  it. Answers how many entries went.

  No condition alone will do. A write to a whole series drops its cached
  rows until the next sync, and a live series' invitation entry carries its
  first occurrence's timing, however long ago that was; that write marks
  the series' entries (`touch_all/2`) so that the gap cannot cost a long
  running series what its guests hold.
  """
  @spec delete_stale(DateTime.t()) :: non_neg_integer()
  def delete_stale(%DateTime{} = cutoff) do
    cutoff = DateTime.truncate(cutoff, :second)
    cutoff_date = DateTime.to_date(cutoff)

    query =
      from(e in SeriesEntrySchema,
        as: :entry,
        where: not exists(cached_occurrences()) and not exists(live_entries(cutoff, cutoff_date))
      )

    {count, _rows} = Repo.delete_all(query)

    count
  end

  # A cached row of the series the `:entry` row belongs to, as
  # `Tymeslot.CalendarGrid.Occurrence.series_address/1` addresses it: by its
  # master, which a master's own row carries as its provider id, or by its
  # CalDAV resource. Matching an unrelated row only keeps a record longer.
  defp cached_occurrences do
    from(c in ProviderCalendarEventSchema,
      where:
        c.calendar_integration_id == parent_as(:entry).calendar_integration_id and
          (fragment("'master:' || ?", c.recurring_event_id) == parent_as(:entry).series_address or
             fragment("'master:' || ?", c.provider_event_id) == parent_as(:entry).series_address or
             fragment("'resource:' || ?", c.provider_event_id) ==
               parent_as(:entry).series_address),
      select: 1
    )
  end

  defp live_entries(cutoff, cutoff_date) do
    from(o in SeriesEntrySchema,
      where:
        o.calendar_integration_id == parent_as(:entry).calendar_integration_id and
          o.series_address == parent_as(:entry).series_address and
          (o.end_at >= ^cutoff or o.end_date >= ^cutoff_date or o.updated_at >= ^cutoff),
      select: 1
    )
  end

  # Each later email replaces an entry's timing; its SEQUENCE only rises.
  # A function rather than a module attribute, which would make this
  # module a compile-time dependent of the schema.
  defp keep_highest_sequence do
    from(e in SeriesEntrySchema,
      update: [
        set: [
          start_at: fragment("EXCLUDED.start_at"),
          end_at: fragment("EXCLUDED.end_at"),
          start_date: fragment("EXCLUDED.start_date"),
          end_date: fragment("EXCLUDED.end_date"),
          sent_sequence: fragment("GREATEST(?, EXCLUDED.sent_sequence)", e.sent_sequence),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end
end
