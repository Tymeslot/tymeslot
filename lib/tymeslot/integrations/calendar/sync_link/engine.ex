defmodule Tymeslot.Integrations.Calendar.SyncLink.Engine do
  @moduledoc """
  Writes one placeholder onto a target calendar and keeps the mapping row that
  records where it went.

  This is the *what*, in the split the codebase uses throughout: the worker owns
  the when — dispatch, retries, backoff, and turning outcomes into Oban's
  vocabulary — while everything here is the domain operation, callable outside a
  job. The return contract is `:ok | {:error, term()} | {:discard, term()}` so
  the worker can pass it straight through, but the meaning of the three is
  decided here, where the reason is known.

  ## Deterministic target UIDs

  A placeholder's UID on the target is derived from `{sync_link_id,
  source_uid}`, never generated randomly. CalDAV's PUT is idempotent on a
  caller-supplied UID, so a write repeated after a lost response converges on
  one event instead of leaving two; and the mapping row, if it is ever lost,
  can be rebuilt by recomputing the UID rather than by guessing which event on
  the target was ours.

  Both halves go into the hash. Without `sync_link_id` two links mirroring the
  same source event onto two calendars would derive the same UID, which is
  harmless while the targets differ and a collision the moment they do not.

  ## Orphan compensation

  The hazard `CalendarEventSync.persist_or_compensate/3` documents applies here
  unchanged. If the provider create succeeds and the mapping insert then fails,
  the placeholder exists on the target with nothing pointing at it. The Oban
  retry finds no mapping, treats the event as unmirrored, and creates a second
  placeholder — and Google and Outlook, which assign event ids server-side,
  cannot detect that they already hold the first. Two busy blocks then sit on
  the target, and only one of them will ever be updated or deleted.

  So a failed persist is followed by a delete of the event just created, before
  the error is surfaced, leaving the retry a clean slate. The compensating
  delete is best-effort: if it also fails, the *original* error is still what
  the caller sees, because that is the failure the retry needs to act on. The
  orphan is then logged at warning, which is the only trace it will leave.

  ## Deleting

  `unmirror/3` is deliberately asymmetric with `mirror/3`. The provider delete
  goes first and the mapping row is dropped only once it succeeds, because the
  row holds the `target_uid` that identifies the placeholder — deleting it first
  would strand a busy block on the organiser's calendar that nothing owns and
  nothing will ever clean up. A delete that fails leaves the row behind in
  `pending_delete`, which is exactly the state the reconcile sweep looks for.

  Every call — write, delete, colour patch — names the calendar the placeholder
  is on, because asking the wrong one draws a 404 that this module reads as
  "already gone": the mapping row, the only record of where the placeholder was,
  is dropped and the block stranded. A 404 from the right calendar genuinely
  means gone. The write takes that calendar from the link; the delete takes it
  from the *mapping row*, which recorded it at write time — a link re-pointed
  since leaves its existing placeholders where they were, so it names only where
  the next write would go.

  ## The identifier a write files under

  Which id a mapping row records is decided by `SyncLink.ProviderEventId`, not
  here: the answer differs per provider family and per write verb, and getting
  it wrong produces a row addressing an event no provider holds. See that
  module.

  ## Conflicts, and why they are recorded here

  A mirror is not independently editable: whatever the organiser does to a
  placeholder on the target, the source overwrites it on the next pass, and a
  source deleted while its placeholder was edited takes the placeholder with it.
  Both are defensible resolutions, and both destroy work without saying so —
  which is why each leaves a row in `calendar_sync_conflicts`. The evidence for
  the decision (the etags compared, the timestamps, the provider error) exists
  only inside the branch that made it, so it is recorded there rather than
  reconstructed afterwards from state that has since been overwritten.

  `SyncLink.ConflictLog` owns the classification; this module owns when to ask
  it. The split matters because the same evidence is read on three paths —
  update, delete, and terminal failure — and three independent readings of it is
  how one divergence ends up appended twice under two names.

  ## The mirror colour

  A link may carry a `mirror_colour` so the organiser can see at a glance which
  calendar a busy block came from. It is applied by `SyncLink.MirrorColour`
  after the placeholder is written, and deliberately cannot fail the write —
  see that module for why a patch swallows its own failure.

  ## The mapping row, after the write

  Advancing the row once a provider write has landed belongs to
  `SyncLink.MirrorRow`, and it is split out for the same reason the colour is:
  it runs under the opposite rule to everything else here. This module returns
  its failures so Oban retries them; that one swallows its own, because by the
  time it runs the placeholder is already correct on the target and a retry
  would rewrite an event that needs nothing to fix a bookkeeping entry the
  reconcile sweep would have corrected anyway. Reading a `case` that drops its
  error inline here made that look like a missing branch rather than a
  decision.

  ## The attempt count

  `write_failed` is the one conflict that turns on something the domain cannot
  see: whether Oban will try again. A retryable error is a write still in
  flight, not a resolution, and recording each attempt would fill the history
  with rows for writes that succeeded seconds later. So the caller passes its
  attempt number — exactly as `Meetings.CalendarEventSync` takes one, for the
  same purpose — and only the final attempt records a failure.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.SyncLink.ConflictLog
  alias Tymeslot.Integrations.Calendar.SyncLink.DeletedSeries
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorColour
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorRow
  alias Tymeslot.Integrations.Calendar.SyncLink.MoveCorrection
  alias Tymeslot.Integrations.Calendar.SyncLink.OrphanCompensation
  alias Tymeslot.Integrations.Calendar.SyncLink.ProviderEventId
  alias Tymeslot.Integrations.Calendar.SyncLink.RecurringSeries
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteEtag

  import Tymeslot.Integrations.Calendar.SyncLink.ProviderEventId, only: [wrote?: 1]

  @uid_prefix "tymeslot-mirror-"

  # Bound at compile time from the schema, which is where the set is stated.
  # Attributes rather than direct calls because `update_mirror/7` matches
  # `@state_pending_delete` in a function head, and a pattern admits no call.
  # That head is the reason these are named at all: a literal misspelt there
  # falls through to the rewrite clause instead of raising, resurrecting a
  # placeholder a teardown is mid-way through withdrawing. A misspelt attribute
  # does not compile.
  @state_active CalendarSyncMirrorSchema.state_active()
  @state_pending_delete CalendarSyncMirrorSchema.state_pending_delete()
  @state_failed CalendarSyncMirrorSchema.state_failed()

  # Matches `SyncLinkWriteBackWorker`'s `max_attempts`. A caller passing no
  # attempt is not running under Oban — a sweep, a console, a test — and has no
  # retry pending, so its failure is terminal where it stands.
  @final_attempt 5

  @typedoc "What the worker maps straight onto Oban's return vocabulary."
  @type result :: :ok | {:error, term()} | {:discard, term()}

  @typedoc """
  `:attempt` is the caller's Oban attempt number. It decides only whether a
  provider failure is recorded as a resolved conflict or left alone as a write
  still being retried.
  """
  @type opts :: [attempt: pos_integer()]

  @doc """
  Creates or updates the placeholder for one source event on this link's target.

  Whether it creates or updates is decided by the mapping row, not by asking the
  provider: the row is the record of what Tymeslot has written, and a lookup per
  event against three provider APIs would cost a round trip per event on every
  sync.

  Eligibility is *not* re-checked here. `Eligibility.mirror_source?/3` is the
  single gate and every caller passes through it first; repeating the check with
  a mirror set this module would have to fetch itself would make it two gates
  that can disagree.
  """
  @spec mirror(CalendarSyncLinkSchema.t(), map(), integer(), opts()) :: result()
  def mirror(%CalendarSyncLinkSchema{} = link, source_event, user_id, opts \\ [])
      when is_integer(user_id) and is_list(opts) do
    if Eligibility.target_writable?(link, user_id) do
      do_mirror(link, source_event, user_id, opts)
    else
      {:discard, :target_unavailable}
    end
  end

  defp do_mirror(link, source_event, user_id, opts) do
    source_uid = source_event.uid
    target_uid = target_uid_for(link.id, source_uid)
    final? = final_attempt?(opts)

    case resolve_series(link, source_event, opts) do
      {:ok, series_opts} ->
        write(link, source_event, source_uid, target_uid, user_id, final?, series_opts)

      # The series is gone: the placeholder comes down rather than being
      # rewritten, and the source's cache row goes with it. See
      # `SyncLink.DeletedSeries`.
      :series_deleted ->
        DeletedSeries.retire(link.source_integration_id, source_uid, fn ->
          unmirror(link, source_uid, user_id, opts)
        end)

      {:discard, reason} ->
        {:discard, reason}
    end
  end

  defp write(link, source_event, source_uid, target_uid, user_id, final?, series_opts) do
    case CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, source_uid) do
      {:ok, mirror} ->
        update_mirror(link, mirror, source_event, target_uid, user_id, final?, series_opts)

      {:error, :not_found} ->
        create_mirror(link, source_event, target_uid, user_id, final?, series_opts)
    end
  end

  # --- The series master ---
  #
  # A recurring source is mirrored from the *series master's* rule, never from
  # the cached row's — see `SyncLink.RecurringSeries` for why the row's rule
  # describes only the last occurrence. The master is fetched here rather than
  # in the payload builder because it is a provider call, and once per
  # `mirror/4` rather than per occurrence: the series is one cache row, so one
  # change is one fetch however many times it recurs.
  #
  # A master that cannot be described is a `:discard`, not an `:error`. Retrying
  # would re-fetch the same absent master and reach the same answer, and the
  # reconcile sweep already looks for exactly the mirrors that are missing —
  # so the retry ladder would spend five attempts to arrive where the sweep
  # starts. A transient failure is therefore *deliberately* discarded too: the
  # sweep is the retry, and the alternative to waiting for it is writing a block
  # at the wrong date.
  #
  # The master's EXDATE lines travel with its rule onto the placeholder. That
  # covers a master carrying them, not a cancellation made through Google, which
  # leaves the rule untouched and marks the *instance* — see `RecurringSeries`.
  # A cancelled and a moved occurrence are both invisible from here, the cache
  # holding one row per series, so both arrive on `opts[:moved]` from
  # `SyncLink.MovedOccurrence` and are rendered by `MoveCorrection`.
  defp resolve_series(link, source_event, opts) do
    case RecurringSeries.resolve(source_event, link.source_integration) do
      :not_recurring ->
        {:ok, []}

      {:ok, series} ->
        [
          recurrence_rule: series.recurrence_rule,
          exceptions: series.exceptions,
          timing: Map.take(series, [:all_day, :start_at, :end_at, :start_date, :end_date])
        ]
        |> MoveCorrection.apply_to(source_event, Keyword.get(opts, :moved, []))
        |> then(&{:ok, &1})

      # An instruction to withdraw, passed through for `mirror/4`.
      :series_deleted ->
        :series_deleted

      {:skip, reason} ->
        Logger.info("Skipping the mirror for a series whose master could not be read",
          sync_link_id: link.id,
          source_uid: source_event.uid,
          reason: inspect(reason)
        )

        {:discard, :series_master_unavailable}
    end
  end

  @doc """
  Withdraws the placeholder for a source event that is gone, or that has stopped
  being an eligible source.

  A source that was never mirrored is `:ok` rather than an error — the sweep
  and the sync path both call this without first establishing that a mapping
  exists, and "there is nothing to withdraw" is the same outcome as having
  withdrawn it.
  """
  @spec unmirror(CalendarSyncLinkSchema.t(), String.t(), integer(), opts()) :: result()
  def unmirror(%CalendarSyncLinkSchema{} = link, source_uid, user_id, opts \\ [])
      when is_binary(source_uid) and is_integer(user_id) and is_list(opts) do
    case CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, source_uid) do
      {:error, :not_found} -> :ok
      {:ok, mirror} -> delete_mirror(link, mirror, user_id, final_attempt?(opts))
    end
  end

  @doc "The prefix every placeholder UID carries; see `SyncLink.OrphanScan`."
  @spec uid_prefix() :: String.t()
  def uid_prefix, do: @uid_prefix

  @doc """
  The UID a placeholder carries on the target, derived from the link and the
  source event.

  Deterministic and collision-resistant: the same pair always yields the same
  UID, and a source UID of any length or character set yields one that is valid
  everywhere. Google's own `uuid_to_google_event_id/1` re-hashes anything that
  is not base32hex, so the readable prefix here is for the organiser looking at
  a raw iCalendar body, not for the provider.
  """
  @spec target_uid_for(integer(), String.t()) :: String.t()
  def target_uid_for(sync_link_id, source_uid)
      when is_integer(sync_link_id) and is_binary(source_uid) do
    digest =
      :sha256
      |> :crypto.hash("#{sync_link_id}\0#{source_uid}")
      |> Base.encode32(case: :lower, padding: false)
      |> String.slice(0, 32)

    @uid_prefix <> digest
  end

  # --- Create ---

  defp create_mirror(link, source_event, target_uid, user_id, final?, series_opts) do
    payload = payload_for(link, source_event, target_uid, series_opts)

    case CalendarEvents.create_event(payload, {link.target_integration_id, user_id}) do
      {:ok, created} ->
        result = persist_or_compensate(link, source_event, target_uid, created, user_id)

        paint(result, link, target_uid, provider_event_id(created), user_id)

      # The identifier is already taken, and it is taken by a placeholder of
      # ours: Google reserves a deleted event's id, so a mirror that was
      # withdrawn and is being rewritten under the same deterministic id
      # collides with its own tombstone. No number of retries frees it, and
      # the event the id names is exactly the one this write wants to exist —
      # so the write becomes an update. The same create→update fallback the
      # booking path in `Meetings.CalendarEventSync` has always had.
      {:error, :already_exists} ->
        adopt_existing_placeholder(link, source_event, target_uid, user_id, final?, series_opts)

      {:error, reason} ->
        record_write_failure(link, source_event.uid, :create, reason, final?)
        {:error, reason}
    end
  end

  defp adopt_existing_placeholder(link, source_event, target_uid, user_id, final?, series_opts) do
    payload = payload_for(link, source_event, target_uid, series_opts)

    case CalendarEvents.update_event(
           target_uid,
           payload,
           {link.target_integration_id, user_id}
         ) do
      # Google files the event under a hash of `target_uid` and answers with it;
      # CalDAV keeps `target_uid` and answers `:ok`. `ProviderEventId` holds the
      # rule, so no provider-specific mapper is reached from here.
      updated when wrote?(updated) ->
        provider_id = ProviderEventId.for_update(updated, target_uid)

        # The id is resolved here because `for_update/2` has to see the bare
        # `:ok` case, but the response itself travels on: it is the only carrier
        # of the etag this write produced, and collapsing it to `%{uid: id}`
        # here is what would drop the baseline on the 409 create→update
        # fallback alone — a path that is exercised on every rebuild after a
        # bulk withdrawal, so the gap would have looked intermittent.
        result =
          persist_or_compensate(
            link,
            source_event,
            target_uid,
            %{provider_event_id: provider_id, etag: WriteEtag.extract(updated)},
            user_id
          )

        paint(result, link, target_uid, provider_id, user_id)

      {:error, reason} ->
        record_write_failure(link, source_event.uid, :create, reason, final?)
        {:error, reason}
    end
  end

  # See the moduledoc. The provider event exists from this point on; if the row
  # recording it cannot be written, the event has to go before the error does.
  defp persist_or_compensate(link, source_event, target_uid, created, user_id) do
    attrs = %{
      sync_link_id: link.id,
      source_uid: source_event.uid,
      target_integration_id: link.target_integration_id,
      # Where the placeholder actually went, captured at write time rather than
      # re-derived from the link later: a link that is re-pointed afterwards
      # leaves this placeholder behind on the calendar named here, and this is
      # then the only record of it. See the schema's moduledoc.
      target_calendar_id: link.target_calendar_id,
      target_uid: target_uid,
      target_provider_event_id: provider_event_id(created),
      # The placeholder as this write left it, read from the write's own
      # response. `nil` for a provider that reports none, which switches the
      # etag-based conflict kinds off for it rather than inventing a baseline.
      target_etag: WriteEtag.extract(created),
      source_updated_at: Map.get(source_event, :provider_updated_at),
      source_etag: Map.get(source_event, :etag),
      last_synced_at: DateTime.utc_now(),
      state: @state_active
    }

    case CalendarSyncMirrorQueries.create(attrs) do
      {:ok, _mirror} ->
        :ok

      {:error, reason} ->
        OrphanCompensation.delete_orphan(link, target_uid, user_id, target_calendar_opts(link))
        {:error, reason}
    end
  end

  # --- Update ---

  # A placeholder already being withdrawn is not rewritten, and the state is
  # read rather than overwritten because those are two different intentions
  # meeting on one row.
  #
  # `pending_delete` is set by a teardown whose provider delete failed — a link
  # removed, a calendar disconnected, an account deleted — and the reconcile
  # sweep is already retrying it. Meanwhile the push path can still reach the
  # same mapping: the source event is unchanged, so an ordinary sync enqueues an
  # upsert for it. Writing the active state there resurrects a mapping whose
  # placeholder is being removed, and the two paths then fight — the sweep
  # enqueueing a delete while the push path rewrites what it just deleted, for
  # as long as both keep running.
  #
  # Discarding is right rather than erroring: no retry helps, because nothing
  # here is broken. The teardown decided this placeholder goes, and that
  # decision outranks a sync that has not noticed yet.
  defp update_mirror(
         _link,
         %CalendarSyncMirrorSchema{state: @state_pending_delete},
         _source_event,
         _target_uid,
         _user_id,
         _final?,
         _series_opts
       ),
       do: {:discard, :mirror_pending_delete}

  defp update_mirror(link, mirror, source_event, target_uid, user_id, final?, series_opts) do
    payload = payload_for(link, source_event, target_uid, series_opts)

    case CalendarEvents.update_event(target_uid, payload, {link.target_integration_id, user_id}) do
      # Both success shapes, for the reason given at
      # `adopt_existing_placeholder/6`. Matching only the CalDAV `:ok` here
      # crashed every Google and Outlook rewrite with a `CaseClauseError`,
      # hidden because every test of this path returned the CalDAV shape.
      updated when wrote?(updated) ->
        # Recorded only once the overwrite has actually landed. A conflict is a
        # resolution, and a write that failed resolved nothing — logging before
        # the call would append a row per retry for a divergence still
        # outstanding, and the retry that finally succeeds would append one
        # more. The evidence survives the write either way: the placeholder's
        # cached state is a projection of the target's own sync, which this
        # write does not touch.
        ConflictLog.record_overwrite(mirror, source_event)

        # The id the provider filed this write under, which need not be what
        # the row already holds. `for_update/2` falls back to the uid the write
        # was addressed to, so a CalDAV `:ok` keeps what it always kept.
        provider_id = ProviderEventId.for_update(updated, target_uid)

        # The new baseline is this write's own etag, replacing the one the
        # divergence above was just read against. A write that reports none
        # clears it rather than leaving the previous one standing: a stale
        # baseline describes a placeholder two writes ago, so comparing against
        # it would report an edit nobody made.
        MirrorRow.mark(mirror, %{
          state: @state_active,
          last_synced_at: DateTime.utc_now(),
          target_etag: WriteEtag.extract(updated),
          target_provider_event_id: provider_id,
          source_updated_at: Map.get(source_event, :provider_updated_at),
          source_etag: Map.get(source_event, :etag)
        })

        paint(:ok, link, target_uid, provider_id, user_id)

      # The placeholder is gone from the target — almost always because the
      # organiser deleted the unexplained "Busy" block by hand. The source event
      # is untouched and still occupies the time, so the answer is to write it
      # again rather than to record a failure: leaving it would keep the mapping
      # insisting the slot is covered while the slot is bookable, which is the
      # double booking this whole feature exists to prevent.
      #
      # Recreating rather than erroring is the same recovery
      # `Meetings.CalendarEventSync` performs for the same reason, and it
      # converges: `target_uid` is derived from the link and source uid, so the
      # replacement carries the identity the mapping already names.
      {:error, :not_found} ->
        recreate_missing(link, mirror, source_event, target_uid, user_id, series_opts)

      {:error, reason} ->
        # The placeholder on the target is now out of step with its source, and
        # only the row records that. Marking it here is what lets the reconcile
        # sweep find it after Oban has exhausted its attempts.
        MirrorRow.mark(mirror, %{state: @state_failed})
        record_write_failure(link, mirror.source_uid, :update, reason, final?)
        {:error, reason}
    end
  end

  # The mapping row survives, so this is an update of where the placeholder
  # lives rather than a fresh mirror: dropping the row and re-creating would
  # lose the source state the conflict log compares against, and would race the
  # sweep, which reads a missing mapping as "never mirrored".
  #
  # The resolved `series_opts` travel here for the same reason they travel to
  # every other write. Recreating without them rebuilds a recurring source as a
  # single block at the cached row's time — which under `singleEvents=true` is
  # the *last* occurrence, months from where the series starts — and then marks
  # the row active, so the sweep sees a fresh mapping and never corrects it.
  defp recreate_missing(link, mirror, source_event, target_uid, user_id, series_opts) do
    payload = payload_for(link, source_event, target_uid, series_opts)

    case CalendarEvents.create_event(payload, {link.target_integration_id, user_id}) do
      {:ok, created} ->
        # Re-baselined like any other write. The row survives a recreate, so
        # without this it would keep the etag of the placeholder the organiser
        # deleted — a baseline for an event that no longer exists, which the
        # next pass would compare against the replacement and read as an edit.
        MirrorRow.mark(mirror, %{
          state: @state_active,
          last_synced_at: DateTime.utc_now(),
          target_etag: WriteEtag.extract(created),
          target_provider_event_id: provider_event_id(created),
          source_updated_at: Map.get(source_event, :provider_updated_at),
          source_etag: Map.get(source_event, :etag)
        })

        :ok

      {:error, reason} ->
        MirrorRow.mark(mirror, %{state: @state_failed})
        {:error, reason}
    end
  end

  # --- Delete ---

  defp delete_mirror(link, mirror, user_id, final?) do
    mirror = consume_delete_race(mirror)

    case CalendarEvents.delete_event(
           mirror.target_uid,
           {link.target_integration_id, user_id},
           CalendarSyncMirrorSchema.target_calendar_opts(mirror, link)
         ) do
      :ok ->
        MirrorRow.drop(mirror)

      # Already gone on the provider. The mapping is the only thing left, and
      # keeping it would make the sweep retry a delete that can never succeed.
      # Sound only because the delete above names the link's own calendar; see
      # the moduledoc's "Deleting".
      {:error, :not_found} ->
        MirrorRow.drop(mirror)

      {:error, reason} ->
        record_write_failure(link, mirror.source_uid, :delete, reason, final?)
        MirrorRow.mark_pending_delete(mirror, reason)
    end
  end

  # The race is recorded before the provider delete, because a delete that fails
  # leaves the mapping in `pending_delete` for the sweep to retry — and the
  # evidence, the placeholder's cached etag, is still there for the retry to
  # find. Recording it on the first pass and then clearing the baseline it was
  # read from is what makes one race one row: the retry has nothing left to
  # compare, and there was never a second race to describe.
  defp consume_delete_race(mirror) do
    case ConflictLog.record_delete_race(mirror) do
      :recorded -> MirrorRow.mark(mirror, %{target_etag: ConflictLog.consumed_baseline()})
      :nothing_to_record -> mirror
    end
  end

  # Only the last attempt records a failure; see the moduledoc. A caller that
  # names no attempt has no retry pending and is treated as final.
  defp final_attempt?(opts), do: Keyword.get(opts, :attempt, @final_attempt) >= @final_attempt

  defp record_write_failure(_link, _source_uid, _operation, _reason, false), do: :ok

  defp record_write_failure(link, source_uid, operation, reason, true),
    do: ConflictLog.record_write_failure(link.id, source_uid, operation, reason)

  # --- Colour ---

  # Delegated so the engine keeps to the write itself. `SyncLink.MirrorColour`
  # owns both halves of the decision — whether a target has colours at all, and
  # what a failed patch means — because the second is the part that reads as an
  # oversight when it sits inline: it is the one step here allowed to fail
  # without failing the write.
  defdelegate colour_target(link), to: MirrorColour, as: :target

  defp paint(result, link, target_uid, provider_event_id, user_id) do
    MirrorColour.apply(
      result,
      link,
      target_uid,
      provider_event_id,
      user_id,
      target_calendar_opts(link)
    )
  end

  # Where this link's placeholders live, in the shape the write payload, the
  # delete opts and the colour patch all take. Empty is the right answer for a
  # link with no `target_calendar_id`, not a missing one: such a link writes to
  # the target's default booking calendar, where a call naming none goes.
  defp target_calendar_opts(%CalendarSyncLinkSchema{target_calendar_id: nil}), do: []

  defp target_calendar_opts(%CalendarSyncLinkSchema{target_calendar_id: id}),
    do: [calendar_id: id]

  # --- Payload ---

  # The privacy tier decides the content; the link decides where it lands.
  # Google and Outlook honour `:calendar_id`, the CalDAV family ignores it and
  # always writes to the primary path — which is why the schema clears
  # `target_calendar_id` for a CalDAV target rather than storing a preference
  # the write cannot honour.
  defp payload_for(link, source_event, target_uid, series_opts) do
    source_event
    |> MirrorPayload.build(target_uid, link,
      recurrence_rule: Keyword.get(series_opts, :recurrence_rule),
      recurrence_exception_lines: Keyword.get(series_opts, :exceptions),
      timing: Keyword.get(series_opts, :timing)
    )
    |> then(&Enum.into(target_calendar_opts(link), &1))
  end

  # The id the provider filed the placeholder under. Which key carries it
  # differs per provider family and per layer, and a `nil` answer is the defect
  # that left 420 mapping rows addressing nothing — `ProviderEventId` holds both
  # facts and the reasoning behind them. Delegated rather than restated so the
  # two cannot drift.
  defp provider_event_id(shape), do: ProviderEventId.extract(shape)
end
