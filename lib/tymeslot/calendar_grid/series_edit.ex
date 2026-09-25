defmodule Tymeslot.CalendarGrid.SeriesEdit do
  @moduledoc """
  Editing a member of a recurring series from the grid, in one of the scopes
  of `Tymeslot.CalendarGrid.RecurrenceScope`: this event, this and every
  following one, or all of them.

  `Tymeslot.CalendarGrid.EventEdit.update_event/4` routes an edit here when
  the cached row belongs to a series. What a scope takes depends on how the
  row's provider addresses part of a series, which
  `Tymeslot.CalendarGrid.Occurrence.series_family/1` answers once for edits
  and deletes alike:

    * **Google and Outlook** give every occurrence an id of its own. An edit
      of this event only is written to that id, exactly like an edit of a
      one-off event. "This and following" and "all events" need a write to
      the series' master, and are refused with `:unsupported_scope` until
      that write exists.
    * **The CalDAV family** holds a whole series in one resource. An edit of
      this event only is written as the occurrence's `RECURRENCE-ID` override
      in that resource (see `Calendar.Events.update_event/3`), and every
      cached row of the resource is given the document the server now holds.
      The wider scopes are refused with `:unsupported_scope` until the
      writer can split or rewrite the series.
    * **Exchange** has no scoped write. An edit of this event is written to
      the item's own id, as it always has been; the wider scopes are refused
      with `:unsupported_scope`.

  ## What one CalDAV occurrence can take

  The override carries only what the edit changed, plus the occurrence's
  timing: whatever else the occurrence has is already in the override the
  writer starts from, the master's own lines or an earlier override, and is
  kept as the server wrote it rather than rewritten from the cache. Two edits
  are refused before anything is written, since they are not edits of one
  occurrence: a change of repeat rule (`:unsupported_scope`; the rule belongs
  to the series) and turning one occurrence all-day or back
  (`:value_type_change`; RFC 5545 allows it, but servers disagree about it).

  ## Failure

  A failed write of a series member is never queued for offline replay. The
  CalDAV offline queue refuses to replay a series member, so a queued edit
  would sit in the queue for good while the grid showed it as saved.
  """

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.RecurrenceScope

  # The fields of a CalDAV occurrence an edit can change, in the cache's
  # vocabulary, which the payload shares for these; timing is always written.
  @override_fields [:summary, :description, :location, :colour, :reminders, :attendees]

  @doc """
  How a series member whose provider is in `family` may be edited from the
  grid: `{:ok, :single}` outside a series, `{:ok, :series}` when the edit
  takes a scope, `{:error, :recurring_event}` when it cannot take one.
  """
  @spec edit_scopes(Occurrence.series_family()) ::
          {:ok, :single | :series} | {:error, :recurring_event}
  def edit_scopes(:single), do: {:ok, :single}
  def edit_scopes(family) when family in [:provider_ids, :caldav], do: {:ok, :series}
  def edit_scopes(:unsupported), do: {:error, :recurring_event}

  @doc """
  Applies `changes` to `event`, a member of a series whose cached row is
  `stored` and whose provider is in `family`, in `scope`.

  Returns what `EventEdit.update_event/4` returns, except that a failure is
  always `:not_queued` (see the moduledoc).
  """
  @spec update_event(
          pos_integer(),
          map(),
          map() | nil,
          Occurrence.series_family(),
          RecurrenceScope.t(),
          EventEdit.changes(),
          keyword()
        ) :: {:ok, map()} | {:error, EventEdit.failure()}
  def update_event(user_id, event, stored, family, scope, changes, opts)

  def update_event(user_id, event, stored, :caldav, :this_only, changes, opts) do
    with :ok <- ensure_occurrence_edit(stored, changes) do
      EventEdit.write_edit(
        user_id,
        event,
        stored,
        changes,
        opts,
        :never_queue,
        &address_occurrence(&1, stored, changes)
      )
    end
  end

  def update_event(user_id, event, stored, _family, :this_only, changes, opts),
    do: EventEdit.write_edit(user_id, event, stored, changes, opts, :never_queue)

  def update_event(_user_id, _event, _stored, _family, scope, _changes, _opts)
      when scope in [:following, :all],
      do: refuse(:unsupported_scope)

  defp ensure_occurrence_edit(%{} = stored, changes) do
    cond do
      Map.get(changes, :all_day, stored.all_day) != stored.all_day ->
        refuse(:value_type_change)

      Map.get(changes, :recurrence_rule, stored.recurrence_rule) != stored.recurrence_rule ->
        refuse(:unsupported_scope)

      true ->
        :ok
    end
  end

  # Without its cached row nothing says which occurrence of which resource
  # the event is.
  defp ensure_occurrence_edit(nil, _changes), do: refuse(:unaddressable_occurrence)

  # The payload of the whole occurrence becomes an edit of its override: the
  # series' href and the occurrence's key address it, and the cached document
  # and ETag are what the writer rewrites.
  defp address_occurrence(payload, %{provider_event_id: href} = stored, changes)
       when is_binary(href) and href != "" do
    with {:ok, key} <- Occurrence.occurrence_key(stored) do
      occurrence = %{
        href: href,
        key: key,
        timezone: stored.timezone,
        document: stored.raw_ical,
        etag: stored.etag,
        changes: Map.take(payload, [:start_time, :end_time | changed_fields(changes)])
      }

      {:ok, Map.put(payload, :occurrence, occurrence)}
    end
  end

  defp address_occurrence(_payload, _stored, _changes), do: {:error, :unaddressable_occurrence}

  defp changed_fields(changes), do: Enum.filter(@override_fields, &Map.has_key?(changes, &1))

  defp refuse(reason), do: {:error, %{reason: reason, retry: :not_queued}}
end
