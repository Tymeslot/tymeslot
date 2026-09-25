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
      or Outlook occurrence can take*), and an edit of this and every
      following event splits the series in two there (see *What this and
      every following Google or Outlook occurrence can take*).
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
      the item's own id, as it always has been, and the grid does not ask
      for a scope (`edit_scopes/1` answers `:this_only`); the wider scopes
      are refused with `:unsupported_scope`.

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

  ## What this and every following Google or Outlook occurrence can take

  The same as every occurrence, applied to the occurrences from the edited
  one on. The series is split at the occurrence's original start, where the
  series put it (`Occurrence.original_start/1`): the occurrences from there
  on are written as a new series, which takes the edit, and the master is
  then ended before them (`Google.SeriesSplit`, `Outlook.SeriesSplit`). If
  the master cannot be ended, the new series is deleted again and the edit
  fails. An edit of the series' first occurrence is an edit of every
  occurrence, and is written as one.

  The new series is a copy of the master's own fields, not of the provider's
  bookkeeping: Google's Meet link is copied as it is, while an Outlook
  series' Teams meeting is not (creating one would make a new meeting),
  though the join details in its description are. Occurrences edited or
  deleted on their own from the split on do not carry over (Google's
  excluded dates do), and a repeat count the grid cannot count as the
  provider does, such as the second Monday of the month for ten months, is
  refused (`:unsupported_rule`) before anything is written.

  The series' rows are then deleted and a sync requested, as for an edit of
  every occurrence, which brings back both halves; the series' recorded video
  rooms move to the new series, whose occurrences carry its join link on
  (`Tymeslot.CalendarGrid.EventVideoRooms.series_split/3`).

  ## Failure

  A failed write of a series member is never queued for offline replay. The
  CalDAV offline queue refuses to replay a series member, so a queued edit
  would sit in the queue for good while the grid showed it as saved; Google
  and Outlook have no offline queue. A failed write leaves the cached rows
  as they were and requests no sync.
  """

  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias Tymeslot.Infrastructure.AvailabilityCache
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
  takes a scope, and `{:ok, :this_only}` for a member of a series whose
  provider has no scoped write, whose edit is written to that event alone
  (see *Exchange* above).
  """
  @spec edit_scopes(Occurrence.series_family()) :: {:ok, :single | :this_only | :series}
  def edit_scopes(:single), do: {:ok, :single}
  def edit_scopes(family) when family in [:provider_ids, :caldav], do: {:ok, :series}
  def edit_scopes(:unsupported), do: {:ok, :this_only}

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
             (family == :provider_ids and scope in [:following, :all]) do
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
      :provider_ids -> address_master(payload, stored, scope, fields)
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
  # not place in its series; neither says which series to edit. A split also
  # needs the occurrence's original start, where the series is cut.
  defp address_master(payload, %{recurring_event_id: master_id} = stored, scope, fields)
       when is_binary(master_id) and master_id != "" do
    occurrence = %{
      scope: scope,
      master_id: master_id,
      start: if(stored.all_day, do: stored.start_date, else: stored.start_at),
      end: if(stored.all_day, do: stored.end_date, else: stored.end_at),
      changes: Map.take(payload, [:start_time, :end_time | fields])
    }

    with {:ok, occurrence} <- put_slot(occurrence, scope, stored),
         do: {:ok, Map.put(payload, :occurrence, occurrence)}
  end

  defp address_master(_payload, _stored, _scope, _fields),
    do: {:error, :unaddressable_occurrence}

  defp put_slot(occurrence, :all, _stored), do: {:ok, occurrence}

  defp put_slot(occurrence, :following, stored) do
    with {:ok, slot} <- Occurrence.original_start(stored),
         do: {:ok, Map.put(occurrence, :slot, slot)}
  end

  # Runs once the provider accepted the write, with what it answered.
  defp after_write(:this_only, _user_id, _stored, _answer), do: :ok
  defp after_write(:all, user_id, stored, _answer), do: resync_series(user_id, stored)

  defp after_write(:following, user_id, stored, answer) do
    with {:ok, %{tail: %{uid: uid} = tail}} when is_binary(uid) <- answer,
         do: EventVideoRooms.series_split(stored, uid, tail_address(tail))

    resync_series(user_id, stored)
  end

  # How the provider addresses the series a split made: a CalDAV resource by
  # its href, a Google or Outlook series by its id.
  defp tail_address(%{href: href}), do: href
  defp tail_address(%{id: id}), do: id

  # Every cached row of the series now names a slot the series may have left,
  # or, once split, an occurrence another resource now holds, so the rows are
  # dropped and a sync brings the series back as the server
  # holds it; what the write answered is not expanded here, the sync's job.
  #
  # The write addressed the series, so its address is known; it is read again
  # here rather than threaded through, from the same row.
  defp resync_series(user_id, %{calendar_integration_id: integration_id} = stored) do
    with {:ok, address} <- Occurrence.series_address(stored),
         do: EventDeletion.delete_series_rows(integration_id, address)

    AvailabilityCache.invalidate_for_user(user_id)
    request_sync(stored.provider, integration_id)
  end

  @doc """
  Requests the sync the dashboard's Refresh asks for of the integration
  `integration_id`, whose provider is `provider`, after a write that changed
  a whole series: a full fetch for the CalDAV family, whose delta sync could
  miss the change. A failure to enqueue is logged rather than returned, since
  the write it follows has already happened.
  """
  @spec request_sync(String.t() | atom(), pos_integer()) :: :ok
  def request_sync(provider, integration_id) do
    case enqueue_sync(to_string(provider), integration_id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not request a sync after writing a whole series",
          calendar_integration_id: integration_id,
          reason: inspect(reason)
        )
    end
  end

  defp enqueue_sync("google", integration_id),
    do: SyncGoogleCalendarWorker.enqueue(integration_id)

  defp enqueue_sync("outlook", integration_id),
    do: RefreshOutlookCalendarWorker.enqueue(integration_id)

  defp enqueue_sync(_caldav, integration_id),
    do: SyncCalDavCalendarWorker.enqueue_full_fetch(integration_id)

  defp refuse(reason), do: {:error, %{reason: reason, retry: :not_queued}}
end
