defmodule Tymeslot.Integrations.Calendar.SyncLink.MovedOccurrence do
  @moduledoc """
  Reports a single occurrence of a mirrored series that is no longer at the time
  the rule places it — dragged elsewhere, or cancelled outright — and enqueues
  the rewrite that corrects the placeholder.

  ## Why one module answers for both

  A move and a cancellation are one condition seen twice: the placeholder is
  still expanding an occurrence that is not there. They are detected in the same
  pass, over the same uncollapsed batch, from the same per-instance marker, and
  they are corrected by the same `EXDATE` on the same placeholder. Splitting
  them into two modules would state that once each and let the two drift, and a
  series carrying both at once — which the live calendar this was built against
  does — would then be assembled from two lists by every caller.

  What separates them is one field of the description: a `new_start` instant
  means the occurrence moved there, and `nil` means it is gone. `MoveCorrection`
  renders the first as an `EXDATE`/`RDATE` pair and the second as a lone
  `EXDATE`.

  ## What is broken, in both directions

  A mirrored series becomes one recurring placeholder built from the master's
  rule. Moving one occurrence does not touch that rule — Google leaves the RRULE
  alone, adds no EXDATE, and records the move on a separate exception instance —
  so the placeholder still expands the occurrence at the time it was originally
  scheduled for. Two things are then wrong at once, and only naming both of them
  describes the state honestly:

  - the slot the occurrence **left** is still blocked, so the organiser looks
    busy at a time they are free and an invitee is refused a slot that exists;
  - the slot the occurrence **moved to** is not blocked at all, so it can be
    booked over a meeting that is genuinely happening.

  The second is the worse half and the easier one to overlook. This is not
  over-blocking; it is a busy block in the wrong place, which is a different
  and more damaging failure than a busy block too many.

  ## How it is corrected, and why that took a third approach

  Correction was deferred once, and the two approaches costed then both bought
  instance-level fidelity with provider traffic: listing a series' instances on
  every sync, or writing a separate placeholder event per moved occurrence.
  Detection was built first so the decision would have evidence rather than an
  argument, and the evidence arrived — real moves, on real series.

  What closes it is neither of those. `SyncLink.MoveCorrection` renders an
  `EXDATE` at the instant the occurrence left and an `RDATE` at the instant it
  went to, and both travel on the placeholder the engine already rewrites: no
  extra request, no second mirror row, still one placeholder per series. Google
  expands both, which was confirmed against the live API before any of this was
  written.

  The property that made the deferral right is therefore kept. Nothing here
  calls a provider — the moves are attached to an enqueue, and the write that
  was already going to happen carries them.

  ## Why the report survives the correction

  The row is still appended, because the two answer different questions. The
  write puts the block in the right place; the row is what the organiser reads
  when a calendar looked wrong and they want to know what happened to it. A
  correction that left no trace would be a busy block silently moving on someone
  else's calendar.

  ## Why the post-commit seam, and not the cache

  The marker cannot be read from the cache, because it is not there and must not
  be. `singleEvents=true` expands the series, every instance shares one
  `iCalUID`, and `upsert_batch/1` deduplicates on `{calendar_integration_id,
  uid}` keeping the last — so a series is one row, and a per-instance value
  stored on it would be an arbitrary instance's. See `CalendarEvent`'s moduledoc.

  `Sync.post_commit_reconciliation/2` runs *before* that dedup, over the full
  uncollapsed batch of `CalendarEvent` structs, and already iterates it. So the
  moved instance and its unmoved siblings are all in hand there at no extra
  cost, and neither the cache, its unique index nor `upsert_batch/1` — shared by
  availability, booking validation, the grid and every provider — has to move.

  ## Why only a mirrored series

  A moved occurrence on a calendar nobody mirrors has no consequence: there is
  no placeholder standing at the wrong time, because there is no placeholder.
  Reporting it would be a row about a discrepancy that does not exist, which is
  the failure that retired `series_exceptions` — and the conflict log is read
  precisely when someone is trying to find out why a calendar looks wrong, so
  its credibility is the thing it is most expensive to spend.

  The caller supplies the enabled links rather than this module fetching them,
  because `Sync.post_commit_reconciliation/2` already asks
  `CalendarSyncLinkQueries.list_enabled_for_source/1` for the mirror enqueue.
  Asking again would be a second identical query after every sync of every
  calendar, for an answer that cannot have changed in between.

  ## Why one row per series and not per occurrence

  A series with three moved occurrences is one divergence with three parts, not
  three divergences: the organiser fixes it by looking at one series. Three rows
  would also make the log's own count useless as a measure of how often this
  happens, which is the thing being measured.

  ## Why an unchanged set does not append

  This describes a condition that **persists** rather than a moment the next
  write resolves. The placeholder is wrong until the source stops moving or
  correction is built, and every sync of that calendar sees the same divergence
  again. Appending each time would bury the log under repetitions of one finding
  and make the row count read as a frequency it is not. So the moves are
  fingerprinted and compared with the last row of this kind for the same series
  on the same link — a new or changed move appends, an unchanged set does not.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBackQueries

  @kind "occurrence_moved"

  @typedoc """
  One occurrence that has moved: where the rule still places it, and where it
  actually is now.
  """
  @type move :: %{original_start: String.t(), new_start: String.t()}

  @doc """
  Records one row per mirrored series that has at least one moved occurrence.

  `links` is the set of enabled links whose source is this integration, as the
  caller already holds it. An empty list means nothing on this calendar is
  mirrored, so no move on it has a consequence worth reporting and no work is
  done.

  Always `:ok`. This is an observation running beside a sync that has already
  committed; a failure to record it must not become a failure of the sync, for
  the same reason `ConflictLog` swallows its own.
  """
  @spec report(
          [Tymeslot.Integrations.Calendar.CalendarEvent.t()],
          [CalendarSyncLinkSchema.t()]
        ) :: :ok
  def report(_calendar_events, []), do: :ok

  def report(calendar_events, links) when is_list(calendar_events) and is_list(links) do
    case Enum.filter(links, &mirrors_series?/1) do
      [] ->
        :ok

      series_links ->
        calendar_events
        |> Enum.filter(&diverged?/1)
        |> Enum.group_by(&series_key/1)
        |> Enum.each(fn {{uid, recurring_event_id}, moved} ->
          Enum.each(series_links, &record(&1, uid, recurring_event_id, moved))
        end)

        :ok
    end
  end

  # Only a link whose target could hold the series in the first place. A target
  # without `:recurrence` never received a placeholder for it — `Eligibility`
  # refuses the source before the engine is reached — so a row saying its
  # placeholder is in the wrong place describes something that does not exist.
  # The report is read to decide whether moves are worth correcting, and rows
  # for links that were never affected would inflate that count with links that
  # mirror no series at all.
  defp mirrors_series?(%CalendarSyncLinkSchema{target_integration: %{provider: provider}}),
    do: Capability.supports?(provider, :recurrence)

  # An unloaded target cannot be asked, and answering "yes" would log against a
  # link whose capability is unknown. Silence is the safe reading: the write
  # path loads the association, so this is a caller that never wrote anything.
  defp mirrors_series?(_link), do: false

  # The two ways an occurrence stops being at its scheduled time, asked as one
  # question because they have one consequence: a placeholder still expanding an
  # occurrence that is no longer there.
  #
  # They are separate predicates rather than a single loosened one because they
  # are separately true. A cancelled occurrence carries `start_at ==
  # original_start_at` — measured on the live API — so `moved?/1` answers false
  # for it, correctly: nothing moved. Relaxing `moved?/1` to catch it would make
  # it report every unmoved occurrence of every series as a move, which is the
  # opposite failure and a far noisier one.
  defp diverged?(event), do: cancelled?(event) or moved?(event)

  # A cancellation is read from the status, which the normaliser already maps
  # (`google/event_normaliser.ex:106`), and gated on the occurrence naming a
  # series. A cancelled *one-off* event is not this: it is an ordinary deletion,
  # already handled by `Sync.reconcile_deletions/3`, which withdraws the whole
  # placeholder. Excepting an instant out of a series that does not exist would
  # write an EXDATE against no RRULE.
  #
  # `original_start_at` is required rather than falling back to `start_at`
  # because it is the instant the *rule* places the occurrence at, and that is
  # what an EXDATE has to name. For a cancellation the two are equal in every
  # live body measured, but an occurrence that was moved and then cancelled has
  # a `start_at` at the moved time and a rule that still expands the original —
  # excepting the moved instant would leave the original slot blocked forever.
  defp cancelled?(%{status: :cancelled, recurring_event_id: id, original_start_at: original})
       when is_binary(id) and not is_nil(original),
       do: true

  defp cancelled?(_event), do: false

  # A move is the marker differing from the start it was compared against —
  # never merely its presence. Google stamps `originalStartTime` on every
  # exception instance, including one whose only change was its title or its
  # guest list, so presence alone would report a series that has not moved at
  # all. The two values are the same kind by construction: the normaliser fills
  # a `Date` for an all-day occurrence and a UTC `DateTime` for a timed one,
  # matching whichever start the same event carries.
  defp moved?(%{original_start_at: nil}), do: false

  defp moved?(%{all_day: true, original_start_at: %Date{} = original, start_date: %Date{} = now}),
    do: Date.compare(original, now) != :eq

  defp moved?(%{
         all_day: false,
         original_start_at: %DateTime{} = original,
         start_at: %DateTime{} = now
       }),
       do: DateTime.compare(original, now) != :eq

  # A marker whose shape disagrees with the event's own timing — an all-day
  # instance carrying a `DateTime` original, or a timed one with no start — has
  # nothing to compare against. "Cannot tell" is not "moved": the same rule
  # `ConflictLog` states as why absence of evidence is never a conflict.
  defp moved?(_event), do: false

  # `uid` is what a conflict row is scoped by and what the organiser sees, and
  # for a Google series it is the same across every instance. `recurring_event_id`
  # is carried alongside so a row names the master too, and is part of the key so
  # that two series which somehow share a uid cannot be merged into one finding.
  defp series_key(%{uid: uid, recurring_event_id: recurring_event_id}),
    do: {uid, recurring_event_id}

  defp record(%CalendarSyncLinkSchema{} = link, uid, recurring_event_id, moved) do
    occurrences = Enum.sort_by(Enum.map(moved, &describe/1), & &1.original_start)

    detail = %{
      "moved_count" => length(occurrences),
      "recurring_event_id" => recurring_event_id,
      "occurrences" =>
        Enum.map(occurrences, fn move ->
          %{"original_start" => move.original_start, "new_start" => move.new_start}
        end)
    }

    # The rewrite is enqueued whether or not the row is new. The row is
    # deduplicated because a log repeating an unchanged divergence every sync is
    # unreadable; the write is not, because `WriteBack`'s uniqueness already
    # collapses repeats into the one pending job, and skipping it on a
    # second sighting would leave a correction unmade whenever the first
    # enqueue was lost — which is exactly what a plain enqueue arriving after
    # it does. Re-sending is cheap and idempotent; not sending is neither.
    WriteBack.enqueue(link.id, uid, :upsert,
      moved: carry_forward_cancellations(link.id, uid, detail["occurrences"])
    )

    if already_recorded?(link.id, uid, detail) do
      :ok
    else
      append(link.id, uid, detail)
    end
  end

  # A cancellation detected on an earlier sync is carried onto this enqueue, and
  # a move is not.
  #
  # The two differ in whether they can be re-detected. A moved occurrence keeps
  # carrying its `originalStartTime` on every delta that contains it, so the
  # freshest detection is the current truth and an older one must not outlive
  # it — an organiser who drags an occurrence back gets a correction that
  # disappears, which is exactly what `WriteBack`'s "fresh moves win" rule
  # protects. A cancelled occurrence is reported by Google **once**. It cannot
  # be re-detected, so dropping it here loses it permanently, and the second
  # cancellation of a series would silently un-cancel the first.
  #
  # So cancellations accumulate across syncs and moves do not. They are keyed by
  # the instant they except, so re-detecting the same cancellation twice is one
  # entry rather than two, and a fresh entry for an instant always wins over a
  # carried one.
  defp carry_forward_cancellations(sync_link_id, uid, fresh) do
    case WriteBackQueries.pending_moves(sync_link_id, uid) do
      nil ->
        fresh

      pending when is_list(pending) ->
        fresh_instants = MapSet.new(fresh, &Map.get(&1, "original_start"))

        pending
        |> Enum.filter(&cancellation?/1)
        |> Enum.reject(&MapSet.member?(fresh_instants, Map.get(&1, "original_start")))
        |> Enum.concat(fresh)
        |> Enum.sort_by(&Map.get(&1, "original_start"))
    end
  end

  defp cancellation?(%{"new_start" => nil}), do: true
  defp cancellation?(_entry), do: false

  # Both sides as ISO 8601 strings, because `detail` is serialised to JSONB and
  # a `DateTime` would round-trip as a string anyway — doing it here means the
  # stored form is the one the dedup below compares, rather than two encodings
  # of the same instant failing to match.
  # A cancellation has an instant to free and none to block, so `new_start` is
  # `nil` — the shape `MoveCorrection` renders as a lone EXDATE. It is matched
  # before the move clauses because a cancelled occurrence carries a perfectly
  # readable `start_at`, and describing it as a move to that instant would emit
  # an RDATE re-blocking the slot the cancellation just freed.
  defp describe(%{status: :cancelled, all_day: true, original_start_at: original}),
    do: %{original_start: Date.to_iso8601(original), new_start: nil}

  defp describe(%{status: :cancelled, original_start_at: original}),
    do: %{original_start: DateTime.to_iso8601(original), new_start: nil}

  defp describe(%{all_day: true, original_start_at: original, start_date: now}),
    do: %{original_start: Date.to_iso8601(original), new_start: Date.to_iso8601(now)}

  defp describe(%{original_start_at: original, start_at: now}),
    do: %{
      original_start: DateTime.to_iso8601(original),
      new_start: DateTime.to_iso8601(now)
    }

  # The comparison is on the occurrence list alone, not the whole detail map:
  # it is the complete description of the divergence, already ordered, and
  # anything else the map might grow later (a count derived from it, a label)
  # would make an unchanged set of moves look like a new one.
  defp already_recorded?(sync_link_id, uid, detail) do
    case CalendarSyncConflictQueries.last_of_kind(sync_link_id, uid, @kind) do
      {:ok, previous} -> Map.get(previous.detail, "occurrences") == detail["occurrences"]
      {:error, :not_found} -> false
    end
  end

  # `skipped` is the only honest resolution here, and it is the accurate one
  # rather than a placeholder: nothing was changed on the target, and the row
  # exists to say the divergence is still standing.
  defp append(sync_link_id, uid, detail) do
    attrs = %{
      sync_link_id: sync_link_id,
      source_uid: uid,
      kind: @kind,
      resolution: "skipped",
      detail: detail
    }

    case CalendarSyncConflictQueries.append(attrs) do
      {:ok, _conflict} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to record a moved occurrence",
          sync_link_id: sync_link_id,
          source_uid: uid,
          reason: inspect(changeset.errors)
        )

        :ok
    end
  end
end
