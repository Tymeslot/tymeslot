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
      one-off event. An edit of all events is written to the series' master,
      named by the occurrence's `recurring_event_id` (see *What every Google
      or Outlook occurrence can take*). "This and following" is refused with
      `:unsupported_scope` until the writer can split the series.
    * **The CalDAV family** holds a whole series in one resource. An edit of
      this event only is written as the occurrence's `RECURRENCE-ID` override
      in that resource (see `Calendar.Events.update_event/3`), and every
      cached row of the resource is given the document the server now holds.
      An edit of all events is written to the series' master, and moves the
      whole series when the occurrence moved (see *What every CalDAV
      occurrence can take*). An edit of this and every following event
      splits the series in two there (see *What this and every following
      CalDAV occurrence can take*).
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

  ## What every CalDAV occurrence can take

  The master takes the fields the edit changed, and a new repeat rule. A
  move of the occurrence moves the series by as much, on the wall clock of
  its zone, with every exception and override (see
  `ICalBuilder.Series.edit_master/5`). A weekly rule's weekdays turn with a
  move to another day; a rule that pins its occurrences in a way a move
  cannot follow, such as the second Monday of the month, refuses it.
  Removing the repeat rule
  is refused (`:unsupported_scope`), as is turning the series all-day or
  back (`:value_type_change`).

  The document the server now holds could move every occurrence, so the
  series' cached rows are not patched: they are deleted, and a full sync of
  the integration is requested, the one the dashboard's Refresh asks for
  (`Tymeslot.Workers.SyncCalDavCalendarWorker.enqueue_full_fetch/1`), which
  brings the series back as the server holds it.

  ## What this and every following CalDAV occurrence can take

  The same as every occurrence, applied to the occurrences from the edited
  one on. The series is split in two there (`CalDAV.Events.split_series/4`):
  the occurrences from the edited one on move to a new resource in the same
  calendar, which takes the edit, and the series' own resource ends before
  them. An edit of the series' first occurrence is an edit of every
  occurrence, and is written as one. The series' rows are then deleted and a
  full sync requested, as for an edit of every occurrence, which brings back
  both halves; the series' recorded video rooms move to the new resource,
  whose occurrences carry its join link on
  (`Tymeslot.CalendarGrid.EventVideoRooms.series_split/3`).

  ## What every Google or Outlook occurrence can take

  The same as every CalDAV occurrence, written to the master the provider
  keeps: the master is read, and patched with only what the edit changed,
  never rewritten from the occurrence, which would take the master's
  recurrence, reminders and zone with it (`Google.SeriesPatch`,
  `Outlook.SeriesPatch`). A move of the occurrence, from where it shows now,
  moves the master by as much on the wall clock of its own zone, and the
  repeat rule and the dates the series excludes follow it. Occurrences
  edited on their own in the provider are not moved; the provider keeps or
  drops them. A master row, which names no master, is refused with
  `:unaddressable_occurrence`, as its delete is.

  The series' rows, the master's own included, are then deleted and a sync
  of the integration requested, the one the dashboard's Refresh asks for
  (`SyncGoogleCalendarWorker.enqueue/1`, `RefreshOutlookCalendarWorker.enqueue/1`).

  ## Failure

  A failed write of a series member is never queued for offline replay. The
  CalDAV offline queue refuses to replay a series member, so a queued edit
  would sit in the queue for good while the grid showed it as saved; Google
  and Outlook have no offline queue. A failed write leaves the cached rows
  as they were and requests no sync.
  """

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  require Logger

  # The fields of a series member an edit can change, in the cache's
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

  def update_event(user_id, event, stored, family, scope, changes, opts)
      when (family == :caldav and scope in [:this_only, :following, :all]) or
             (family == :provider_ids and scope == :all) do
    with :ok <- ensure_series_edit(stored, scope, changes) do
      EventEdit.write_edit(
        user_id,
        event,
        stored,
        changes,
        opts,
        :never_queue,
        &address(&1, family, stored, scope, changes),
        &after_write(scope, user_id, stored, &1)
      )
    end
  end

  def update_event(user_id, event, stored, _family, :this_only, changes, opts),
    do: EventEdit.write_edit(user_id, event, stored, changes, opts, :never_queue)

  def update_event(_user_id, _event, _stored, _family, scope, _changes, _opts)
      when scope in [:following, :all],
      do: refuse(:unsupported_scope)

  defp ensure_series_edit(%{} = stored, scope, changes) do
    cond do
      Map.get(changes, :all_day, stored.all_day) != stored.all_day ->
        refuse(:value_type_change)

      rule_refused?(scope, stored, changes) ->
        refuse(:unsupported_scope)

      true ->
        :ok
    end
  end

  # Without its cached row nothing says which occurrence of which resource
  # the event is.
  defp ensure_series_edit(nil, _scope, _changes), do: refuse(:unaddressable_occurrence)

  # One occurrence cannot take a rule of its own: the rule is the series'.
  # Every occurrence can take a new rule, but not none: a series whose rule
  # is taken away is one event, whose exceptions and overrides would name
  # slots that no longer exist.
  defp rule_refused?(:this_only, stored, changes), do: rule_changed?(stored, changes)

  defp rule_refused?(scope, _stored, changes) when scope in [:following, :all],
    do: Map.has_key?(changes, :recurrence_rule) and is_nil(changes.recurrence_rule)

  defp rule_changed?(stored, changes),
    do: Map.get(changes, :recurrence_rule, stored.recurrence_rule) != stored.recurrence_rule

  # The payload of the whole occurrence becomes an edit of the series. For
  # CalDAV, its resource: its href and the occurrence's key address it, the
  # scope says whether the writer edits the occurrence's override or the
  # master, and the cached document and ETag are what the writer rewrites.
  # For Google and Outlook, its master, named by the occurrence, with where
  # the occurrence shows now, which is what a move of it is measured from.
  defp address(payload, family, stored, scope, changes) do
    fields = changed_fields(scope, stored, changes)

    case family do
      :caldav -> address_fields(payload, stored, scope, fields)
      :provider_ids -> address_master(payload, stored, fields)
    end
  end

  defp changed_fields(:this_only, _stored, changes),
    do: Enum.filter(@override_fields, &Map.has_key?(changes, &1))

  defp changed_fields(scope, stored, changes) when scope in [:following, :all] do
    fields = changed_fields(:this_only, stored, changes)
    if rule_changed?(stored, changes), do: [:recurrence_rule | fields], else: fields
  end

  defp address_fields(payload, %{provider_event_id: href} = stored, scope, fields)
       when is_binary(href) and href != "" do
    with {:ok, key} <- Occurrence.occurrence_key(stored) do
      occurrence = %{
        href: href,
        key: key,
        scope: scope,
        timezone: stored.timezone,
        document: stored.raw_ical,
        etag: stored.etag,
        changes: Map.take(payload, [:start_time, :end_time | fields])
      }

      {:ok, Map.put(payload, :occurrence, occurrence)}
    end
  end

  defp address_fields(_payload, _stored, _scope, _fields),
    do: {:error, :unaddressable_occurrence}

  # A row naming no master is the master itself, or an event the sync could
  # not place in its series; neither says which series to edit.
  defp address_master(payload, %{recurring_event_id: master_id} = stored, fields)
       when is_binary(master_id) and master_id != "" do
    occurrence = %{
      scope: :all,
      master_id: master_id,
      start: if(stored.all_day, do: stored.start_date, else: stored.start_at),
      end: if(stored.all_day, do: stored.end_date, else: stored.end_at),
      changes: Map.take(payload, [:start_time, :end_time | fields])
    }

    {:ok, Map.put(payload, :occurrence, occurrence)}
  end

  defp address_master(_payload, _stored, _fields), do: {:error, :unaddressable_occurrence}

  # Runs once the provider accepted the write, with what it answered.
  defp after_write(:this_only, _user_id, _stored, _answer), do: :ok
  defp after_write(:all, user_id, stored, _answer), do: resync_series(user_id, stored)

  defp after_write(:following, user_id, stored, answer) do
    with {:ok, %{tail: %{uid: uid, href: href}}} <- answer,
         do: EventVideoRooms.series_split(stored, uid, href)

    resync_series(user_id, stored)
  end

  # Every cached row of the series now names a slot the series may have left,
  # or, once split, an occurrence another resource now holds, so the rows are
  # dropped and a sync brings the series back as the server
  # holds it; what the write answered is not expanded here, the sync's job.
  defp resync_series(user_id, %{calendar_integration_id: integration_id} = stored) do
    delete_series_rows(integration_id, stored)
    AvailabilityCache.invalidate_for_user(user_id)

    case request_sync(to_string(stored.provider), integration_id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not request a sync after editing a whole series",
          calendar_integration_id: integration_id,
          reason: inspect(reason)
        )
    end
  end

  # The occurrences name their master; the master's own row, when cached,
  # carries its id. A CalDAV series is its resource's rows.
  defp delete_series_rows(integration_id, %{recurring_event_id: master_id})
       when is_binary(master_id) and master_id != "" do
    ProviderCalendarEventQueries.delete_by_recurring_event_ids(integration_id, [master_id])
    ProviderCalendarEventQueries.delete_by_provider_event_ids(integration_id, [master_id])
  end

  defp delete_series_rows(integration_id, stored),
    do:
      ProviderCalendarEventQueries.delete_by_provider_event_ids(integration_id, [
        stored.provider_event_id
      ])

  defp request_sync("google", integration_id),
    do: SyncGoogleCalendarWorker.enqueue(integration_id)

  defp request_sync("outlook", integration_id),
    do: RefreshOutlookCalendarWorker.enqueue(integration_id)

  defp request_sync(_caldav, integration_id),
    do: SyncCalDavCalendarWorker.enqueue_full_fetch(integration_id)

  defp refuse(reason), do: {:error, %{reason: reason, retry: :not_queued}}
end
