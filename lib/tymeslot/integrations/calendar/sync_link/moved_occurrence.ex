defmodule Tymeslot.Integrations.Calendar.SyncLink.MovedOccurrence do
  @moduledoc """
  Reports a single occurrence of a mirrored series that has been dragged to a
  different time, and does nothing whatsoever to correct it.

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

  ## Why this only detects

  Correcting a move needs either a per-instance override written onto the
  target, or a listing of the source series' instances to diff against the rule.
  Both were costed and deferred. Detection exists so that the decision about
  whether to pay for them has evidence — how often this actually happens, and
  on which series — instead of an argument. Nothing here writes to a provider,
  and the absence of a provider call is a property to preserve: a per-series
  request added here would put the cost that got correction deferred into the
  step that exists to measure it.

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
        |> Enum.filter(&moved?/1)
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

    if already_recorded?(link.id, uid, detail) do
      :ok
    else
      append(link.id, uid, detail)
    end
  end

  # Both sides as ISO 8601 strings, because `detail` is serialised to JSONB and
  # a `DateTime` would round-trip as a string anyway — doing it here means the
  # stored form is the one the dedup below compares, rather than two encodings
  # of the same instant failing to match.
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
