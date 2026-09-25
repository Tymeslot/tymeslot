defmodule Tymeslot.CalendarGrid.EventEdit do
  @moduledoc """
  Editing an existing calendar-grid event: one change applied to the whole
  event, pushed to the provider, then written back to the cache.

  ## Why the whole event is sent

  Provider updates are full replaces, so a rename that sent only the title
  used to strip the event's attendees, reminders, repeat rule and colour. The
  payload is therefore always built by `Tymeslot.CalendarGrid.ProviderPayload`
  from the complete event after the change is applied, never from the change
  alone. `changes` speaks the cache's vocabulary; that module is the one place
  it is translated into the adapters'.

  That keeps everything the cache models, which is not everything the event
  has: an event authored elsewhere carries properties Tymeslot never reads.
  For the CalDAV family the payload therefore travels with the cached
  `raw_ical` and its ETag, and the adapter patches that document property by
  property instead of rebuilding it, so an `ATTENDEE` block with its
  `PARTSTAT`, categories and `X-` properties survive an edit. Google and
  Outlook have no equivalent: their updates replace the event with the
  payload, and what the cache does not model is still lost there.

  Attendees are the one exception to "always the whole event". Outlook's
  update is a `PATCH` and a patched CalDAV document keeps what the payload
  leaves out, so on those writes the guest list is sent only by an edit that
  changes it: a Graph `PATCH` that carries attendees resets every reply, and
  a CalDAV write that carries them states the new complete list.

  ## Recurring events

  An edit of a member of a series applies to a
  `Tymeslot.CalendarGrid.RecurrenceScope`: this event, this and following, or
  all of them. `update_event/4` hands such an edit to
  `Tymeslot.CalendarGrid.SeriesEdit`, which decides per provider family what
  each scope writes, and which scopes are refused. Whichever it picks ends in
  `write_edit/6`, the same write a one-off event takes. Google and Outlook
  address an occurrence by its own id, so an edit of that one occurrence is
  written like any other event; an edit of all of them is addressed to the
  series' master, which the provider patches with only what changed.

  ### The CalDAV family

  A CalDAV series lives in one resource: the master VEVENT carrying the
  `RRULE`, plus a VEVENT per occurrence that has been edited on its own. The
  sync never stores that master — it expands it into one cached row per
  occurrence, all sharing the series' href — and
  `ICalBuilder.Patcher.patch/2` applies the payload to the master and skips
  every `RECURRENCE-ID` override. The ordinary write would therefore land on
  the whole series, and since the payload always carries the occurrence's
  own `DTSTART`, even a rename would move the series onto that occurrence.

  So an edit of one CalDAV occurrence does not take that write. `SeriesEdit`
  hands `write_edit/8` an address that turns the payload into an override of
  the occurrence (see `Calendar.Events.update_event/3`), and the provider
  answers with the document the series now lives in, which every cached row
  of the resource is given (see `ProviderCalendarResourceQueries`). An edit
  of all of them is addressed the same way and written to the series'
  master, and an edit of it and every following one to a split of the
  series; `SeriesEdit` then drops the series' rows and has the sync bring
  them back.

  ## Failure

  A failed provider write is queued for replay when the error is one a retry
  can recover (see `Calendar.Events.queueable_error?/1`) and the integration
  has an offline queue (the CalDAV family). A queued edit is also written to
  the cache, so the grid keeps showing what the organiser saved. An edit of a
  series member is never queued (see `Tymeslot.CalendarGrid.SeriesEdit`).
  """

  alias Tymeslot.CalendarGrid.AllDay
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.ProviderPayload
  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias Tymeslot.CalendarGrid.SeriesEdit
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarResourceQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  require Logger

  @editable_fields ~w(summary description location start_at end_at all_day start_date end_date reminders recurrence_rule colour attendees)a

  @typedoc "An allowlisted map of cache fields to their new values."
  @type changes :: %{optional(atom()) => term()}

  @type failure :: %{reason: term(), retry: :queued | :not_queued}

  @typedoc "Whether a failed provider write may be queued for offline replay."
  @type retry_policy :: :queue_recoverable | :never_queue

  @doc """
  Applies `changes` to `event`, writes the whole updated event to the
  provider, and records the edit on the cached row.

  `changes` may only carry #{Enum.map_join(@editable_fields, ", ", &"`#{&1}`")};
  any other key raises `ArgumentError`. Timing follows the event's resulting `all_day`
  flag: an all-day event keeps its dates and drops its timestamps, a timed
  event the reverse. A change that flips `all_day` also refits the `UNTIL` of
  a recurring event's rule to the value type its new `DTSTART` calls for.

  ## Options

    * `:recurrence_scope` - which occurrences of a recurring series the edit
      applies to, a `t:Tymeslot.CalendarGrid.RecurrenceScope.t/0`; defaults to
      `:this_only`, and is ignored for an event outside a series. Anything
      else raises `ArgumentError`: a scope arriving from a form is parsed with
      `RecurrenceScope.parse/1` first. See `Tymeslot.CalendarGrid.SeriesEdit`.
    * `:conference_data` - a change to a Google event's own conference, sent
      with the write: a `createRequest` from
      `Tymeslot.Integrations.Calendar.Google.ConferenceData.create_request/0`,
      or `ConferenceData.remove/0`. Without it the event's conference is left
      as it is.
    * `:timezone` - the organiser's timezone. A timed event's `UNTIL` is an
      instant (RFC 5545 §3.3.10), so refitting one has to end the organiser's
      chosen day in their own zone; without it the day ends in UTC and the
      series gains or loses its last occurrence.

  Returns `{:ok, updated_event}`, or `{:error, %{reason: reason, retry:
  :queued | :not_queued}}` where `:queued` means the edit is saved locally
  and will be replayed on the next sync. An edit of a series member is never
  queued, and a scope its provider cannot write is refused with
  `:unsupported_scope` before anything is written (see
  `Tymeslot.CalendarGrid.SeriesEdit`).
  """
  @spec update_event(pos_integer(), map(), changes(), keyword()) ::
          {:ok, map()} | {:error, failure()}
  def update_event(user_id, event, changes, opts \\ []) when is_map(changes) do
    ensure_known_fields!(changes)
    scope = recurrence_scope!(opts)

    # The cache row, read once and used throughout: it is what says whether
    # the event belongs to a series, since the caller's copy may be an
    # optimistic one built from a form, and it carries the document the CalDAV
    # adapters patch.
    stored = stored_row(event)

    case Occurrence.series_family(stored || event) do
      :single -> write_edit(user_id, event, stored, changes, opts, :queue_recoverable)
      family -> SeriesEdit.update_event(user_id, event, stored, family, scope, changes, opts)
    end
  end

  @doc """
  How `event` may be edited from the grid: `{:ok, :single}` for an event
  outside any series, `{:ok, :series}` for a member of one whose edit takes a
  scope, and `{:error, :recurring_event}` for a series whose provider has no
  scoped edit. Reads the cached row, as `update_event/4` does. See
  `Tymeslot.CalendarGrid.SeriesEdit`.
  """
  @spec edit_scopes(map()) :: {:ok, :single | :series} | {:error, :recurring_event}
  def edit_scopes(event) do
    (stored_row(event) || event)
    |> Occurrence.series_family()
    |> SeriesEdit.edit_scopes()
  end

  @typedoc """
  Turns the payload of a whole event into the write the provider is given,
  or refuses it before anything is written.
  """
  @type address :: (map() -> {:ok, map()} | {:error, term()})

  @typedoc """
  Given what the provider answered a successful write: `:ok`, or
  `{:ok, answer}` with the document a rewritten resource now holds.
  """
  @type answered :: (:ok | {:ok, map()} -> term())

  @doc """
  The write every edit ends in, once it is known which event it lands on:
  applies `changes` to `event`, writes the whole updated event to the
  provider, and records the edit on the cached row `stored`.

  `retry` says what a failed write does: `:queue_recoverable` queues one a
  retry can recover (see the moduledoc), `:never_queue` reports every failure
  as `:not_queued`. `address` gets the last word on the payload; by default
  it is written as built. A provider that rewrote a resource the event shares
  with others answers with its new document, and every cached row of the
  resource is given it. `answered` is handed the provider's answer once the
  write succeeded, before the result is returned; by default it is ignored.

  Called by `update_event/4` and by `Tymeslot.CalendarGrid.SeriesEdit`;
  everything else goes through `update_event/4`.
  """
  @spec write_edit(
          pos_integer(),
          map(),
          map() | nil,
          changes(),
          keyword(),
          retry_policy(),
          address(),
          answered()
        ) :: {:ok, map()} | {:error, failure()}
  def write_edit(
        user_id,
        event,
        stored,
        changes,
        opts,
        retry,
        address \\ &{:ok, &1},
        answered \\ fn _answer -> :ok end
      ) do
    with {:ok, updated} <- apply_changes(event, changes, opts),
         {:ok, payload} <- ProviderPayload.from_event(updated),
         {:ok, payload} <-
           payload
           |> maybe_put_conference(Keyword.get(opts, :conference_data))
           |> put_stored_document(stored)
           |> scope_attendees(event, changes)
           |> address.() do
      write_to_provider(user_id, event, updated, payload, retry, answered)
    else
      {:error, reason} -> {:error, %{reason: reason, retry: :not_queued}}
    end
  end

  defp recurrence_scope!(opts) do
    scope = Keyword.get(opts, :recurrence_scope, :this_only)

    if scope in RecurrenceScope.values() do
      scope
    else
      raise ArgumentError,
            "expected :recurrence_scope to be one of #{inspect(RecurrenceScope.values())}, " <>
              "got: #{inspect(scope)}"
    end
  end

  @doc """
  Whether `event` may be edited from the grid. Every event may: an edit of a
  member of a series writes one occurrence by default, which every provider
  family can address (see `Tymeslot.CalendarGrid.SeriesEdit`).

  Kept as the gate the grid's edit handlers go through, so a family that
  cannot write even one occurrence is refused in one place, before any
  optimistic update, should one arrive.
  """
  @spec ensure_editable(map()) :: :ok | {:error, :recurring_event}
  def ensure_editable(_event), do: :ok

  defp stored_row(event) do
    case ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid) do
      {:ok, row} -> row
      {:error, :not_found} -> nil
    end
  end

  # The document the provider last gave us, for the adapters that can patch it
  # rather than rebuild the event from the payload. It is read from the cache
  # row rather than taken off `event`, which is whatever the grid last
  # assigned and may be an optimistic copy built from a form: a payload that
  # quietly arrived without a document would be rebuilt, which is the loss
  # this exists to prevent.
  defp put_stored_document(payload, %{raw_ical: raw_ical} = row)
       when is_binary(raw_ical) and raw_ical != "",
       do: Map.merge(payload, %{raw_ical: raw_ical, etag: row.etag})

  defp put_stored_document(payload, _never_synced), do: payload

  # Google's `events.update` is a `PUT`, so its payload has to carry the guest
  # list on every write or the guests are deleted. Outlook's `PATCH` and a
  # patched CalDAV document are merges instead: a key the payload leaves out
  # keeps its value on the server. There, sending the list with an edit that
  # is not about attendees can only do harm. Graph replaces the collection,
  # and every reply with it, and a stale or empty cached list would take the
  # guests off the event. So those writes carry attendees only when the edit
  # changes them. A CalDAV event with no stored document is rebuilt from the
  # payload, not patched, and keeps the whole list.
  defp scope_attendees(payload, _event, %{attendees: _attendees}), do: payload

  defp scope_attendees(payload, event, _changes) do
    if merges_attendees?(Map.get(event, :provider), payload),
      do: Map.delete(payload, :attendees),
      else: payload
  end

  defp merges_attendees?(provider, _payload) when provider in [:outlook, "outlook"], do: true

  defp merges_attendees?(provider, %{raw_ical: _stored_document}),
    do: ProviderConfig.caldav_based?(provider)

  defp merges_attendees?(_provider, _payload), do: false

  defp write_to_provider(user_id, event, updated, payload, retry, answered) do
    case CalendarEvents.update_event(event.uid, payload, {event.calendar_integration_id, user_id}) do
      :ok ->
        result = written(user_id, updated)
        answered.(:ok)
        result

      {:ok, %{document: document}} = answer ->
        result = written(user_id, updated)
        share_document(event, payload, document)
        answered.(answer)
        result

      {:error, reason} ->
        {:error, %{reason: reason, retry: queue_retry(retry, user_id, updated, payload, reason)}}
    end
  end

  defp written(user_id, updated) do
    record_local_edit(user_id, updated)
    # A no-op unless the event holds a recorded video room whose times the
    # change moved.
    EventVideoRooms.rescheduled(updated)
    {:ok, updated}
  end

  # The provider rewrote the resource at the payload's href, which other
  # cached rows share (the rest of a CalDAV series). Each of them is given the
  # new document with no ETag, so the next write to any of them starts from
  # what the server now holds.
  defp share_document(event, %{occurrence: %{href: href}}, document),
    do:
      ProviderCalendarResourceQueries.replace_document(
        event.calendar_integration_id,
        href,
        document
      )

  defp ensure_known_fields!(changes) do
    case Map.keys(changes) -- @editable_fields do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "cannot edit #{inspect(unknown)} on a calendar event; " <>
                "editable fields are #{inspect(@editable_fields)}"
    end
  end

  defp apply_changes(event, changes, opts) do
    event
    |> Map.merge(changes)
    |> normalise_timing()
    |> retarget_rule(event.all_day, Keyword.get(opts, :timezone))
  end

  defp normalise_timing(%{all_day: true} = event), do: %{event | start_at: nil, end_at: nil}
  defp normalise_timing(event), do: %{event | start_date: nil, end_date: nil}

  # RFC 5545 §3.3.10: a rule's UNTIL carries the value type of the event's
  # DTSTART, so flipping all-day leaves a recurring event's existing rule in
  # the wrong form. Every other part of the rule is kept as it was.
  defp retarget_rule(%{all_day: all_day} = updated, all_day, _timezone), do: {:ok, updated}

  defp retarget_rule(updated, _was_all_day, timezone) do
    case RRule.retarget(updated.recurrence_rule,
           all_day: updated.all_day,
           start_date: AllDay.start_date(updated),
           timezone: timezone
         ) do
      {:ok, rule} -> {:ok, %{updated | recurrence_rule: rule}}
      {:error, :until_before_start} = error -> error
    end
  end

  defp maybe_put_conference(payload, nil), do: payload
  defp maybe_put_conference(payload, change), do: Map.put(payload, :conference_data, change)

  defp queue_retry(:never_queue, _user_id, _event, _payload, _reason), do: :not_queued

  defp queue_retry(:queue_recoverable, user_id, event, payload, reason) do
    target = %{uid: event.uid, calendar_integration_id: event.calendar_integration_id}

    with true <- CalendarEvents.queueable_error?(reason),
         :ok <- CalendarEvents.queue_for_offline_retry(target, :update, payload) do
      # The queue tag writes the edit's own fields, so this is no longer
      # repairing what the tag blanked. It stays for the other half of the
      # job: applying the canonical editable-field set to the cached row and
      # invalidating the organiser's availability, which a queued edit has
      # changed locally whether or not it has reached the server yet.
      record_local_edit(user_id, event)
      :queued
    else
      _not_queued -> :not_queued
    end
  end

  # Deliberately no grid broadcast: the organiser's own grid already shows the
  # edit, and a reload would land in the middle of whatever they do next.
  defp record_local_edit(user_id, event) do
    case ProviderCalendarEventQueries.apply_local_edit(
           event.calendar_integration_id,
           event.uid,
           Map.take(event, @editable_fields)
         ) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("Calendar event edit reached the provider but not the cache",
          calendar_integration_id: event.calendar_integration_id,
          reason: inspect(reason)
        )
    end

    AvailabilityCache.invalidate_for_user(user_id)
  end
end
