defmodule Tymeslot.Integrations.Calendar.SyncLink.UnmirrorableSeries do
  @moduledoc """
  Tells the organiser that a repeating event on this link is not being
  mirrored, and which end of the link cannot carry it.

  ## Why a refusal needs a voice at all

  `SyncLink.Eligibility` refuses a recurring source unless both ends of the link
  can handle it: the **source** must be able to have its series master fetched
  (`Capability`'s `:series_lookup`), because the cached row is an expanded
  instance carrying no rule, and the **target** must expand the series it is
  handed (`:recurrence`) rather than writing one block at one occurrence's date.

  The refusal is correct. What was wrong is that it was inaudible. The
  write-back worker turned it into `{:discard, :not_an_eligible_source}`, an
  Oban outcome that reaches a log line and nothing else, so a weekly meeting on
  such a link produced no placeholder, nothing that would ever retry, and no
  mark anywhere an organiser looks. Their Tuesdays stayed bookable and the first
  symptom available to them was a double booking — a failure they would have had
  no way to attribute to the sync link that caused it.

  A skip an organiser can see is a different thing from a skip they cannot. This
  module is the difference.

  ## Why a conflict row rather than the attention panel

  The Integrations Hub's `attention_items/4` was the other candidate and is the
  wrong shape twice over. It is keyed on an *integration* and driven by
  `HealthCheck`, which describes connection state — needs reconnecting, stopped
  syncing — for a calendar as a whole. This condition belongs to neither: it is a
  property of a **link**, since the same source calendar may mirror happily onto
  one target and not another, and of a particular **event** on it, since the
  organiser's remedy is about one repeating meeting rather than about the
  calendar. Filing it as integration health would say a healthy, correctly
  connected calendar was unwell.

  The conflict log already has both keys — `sync_link_id` and `source_uid` — is
  append-only, is rendered per link beneath the link it belongs to, and already
  carries a kind of exactly this character: `occurrence_moved` likewise records
  a divergence the engine has decided *not* to resolve rather than one it
  resolved. So the row goes where the organiser already looks for "why does this
  link's mirroring not match my calendar", and no second surface is invented to
  hold one sentence.

  ## Why this is not in `ConflictLog`

  `ConflictLog` reads *mirror state*: a mapping row, a cached placeholder, two
  etags compared. Every kind it writes is derived from a placeholder that
  exists. This condition is the opposite — it fires precisely when no
  placeholder was ever written and no mapping row exists — so there is nothing
  of `ConflictLog`'s evidence to read. It is the same seam that keeps
  `MovedOccurrence` separate, and for the same reason.

  ## Recorded once, not once per pass

  The write-back worker runs on every change to every event and the reconcile
  sweep runs the whole window every pass, so an unconditional append would file
  the same sentence about the same series until nothing else in the history
  could be found. That would spend the credibility of a log read exactly when
  someone is trying to work out why a calendar looks wrong.

  So a series already reported on a link is not reported again, keyed on
  `{sync_link_id, source_uid, kind}` through `last_of_kind/3` — the same
  suppression `MovedOccurrence` uses. Suppression is per source event rather
  than per link, because two unmirrorable series are two meetings the organiser
  has to do something about.

  The consequence to accept is that a link whose providers change under it — a
  target reconnected from Outlook to Google and back — reports the second
  refusal only if the first row has been pruned. That is the right trade: the
  row already standing says the same true thing, and the alternative is the
  flood above.

  ## Not reachable on every installation, and recorded anyway

  An organiser with two Google calendars can never see one of these rows: Google
  answers both capabilities, so every series mirrors. The condition needs a
  non-Google source or target, and on an installation with neither it is
  unreachable. It is written all the same, because the gate it reports is real
  for anyone who connects an Outlook or CalDAV calendar, and a silent discard
  is not made acceptable by the current shape of one account's integrations.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability

  @kind "series_unsupported"

  @typedoc """
  Whether a row was appended.

  `:nothing_to_record` covers three different situations that all mean "say
  nothing": the event is not a series, the link can carry it, or this series has
  already been reported on this link.
  """
  @type outcome :: :recorded | :nothing_to_record

  @doc """
  Records that this link cannot mirror this recurring source, if that is true
  and has not already been said.

  Answers `:recorded` only when a row was actually appended, so the caller can
  tell a first refusal from a repeat without querying again.

  The `link` must carry both integrations. `CalendarSyncLinkQueries.get/1`
  preloads them and every production caller goes through it; a link without them
  answers as an unrecognised provider at both ends, which is the conservative
  reading — an unresolvable link is exactly the thing worth reporting.
  """
  @spec record(map(), map()) :: outcome()
  def record(link, source) do
    with true <- recurring?(source),
         end_ when is_binary(end_) <- unsupported_end(link) do
      append_unless_reported(link, source, end_)
    else
      _supported_or_not_recurring -> :nothing_to_record
    end
  end

  # The same two marks `Eligibility.recurring?/1` reads, and deliberately the
  # same pair rather than the master id alone. A row carrying an RRULE and no
  # master id is a non-Google ingest — and so is by definition a source whose
  # series cannot be resolved — which makes it the shape most in need of a
  # report, not least.
  defp recurring?(%{recurring_event_id: id}) when is_binary(id) and id != "", do: true
  defp recurring?(%{recurrence_rule: rule}) when is_binary(rule) and rule != "", do: true
  defp recurring?(_source), do: false

  # Which end fails, as the organiser's remedy differs entirely between them:
  # an unresolvable source means the repeating event has to live on a calendar
  # Tymeslot can read a series from, while an incapable target means the link
  # has to point somewhere that expands one. `nil` means the link can carry the
  # series and there is nothing to report.
  defp unsupported_end(link) do
    case {source_ok?(link), target_ok?(link)} do
      {true, true} -> nil
      {false, true} -> "source"
      {true, false} -> "target"
      {false, false} -> "both"
    end
  end

  defp source_ok?(link), do: Capability.supports?(source_provider(link), :series_lookup)
  defp target_ok?(link), do: Capability.supports?(target_provider(link), :recurrence)

  defp source_provider(%{source_integration: %{provider: provider}}), do: provider
  defp source_provider(_link), do: nil

  defp target_provider(%{target_integration: %{provider: provider}}), do: provider
  defp target_provider(_link), do: nil

  defp append_unless_reported(link, source, unsupported_end) do
    uid = Map.get(source, :uid)

    if is_binary(uid) and not already_reported?(link.id, uid) do
      append(link, uid, unsupported_end)
    else
      :nothing_to_record
    end
  end

  defp already_reported?(sync_link_id, uid) do
    case CalendarSyncConflictQueries.last_of_kind(sync_link_id, uid, @kind) do
      {:ok, _previous} -> true
      {:error, :not_found} -> false
    end
  end

  # `skipped` is the accurate resolution rather than a stand-in: nothing was
  # written to the target, and the row exists to say the gap is still standing.
  #
  # Both providers are recorded, not only the failing one. An organiser reading
  # this needs to know which pair of calendars produced it, and a row naming
  # only the end at fault is unreadable once the link's ends have been
  # reconnected since.
  defp append(link, uid, unsupported_end) do
    attrs = %{
      sync_link_id: link.id,
      source_uid: uid,
      kind: @kind,
      resolution: "skipped",
      detail: %{
        "unsupported_end" => unsupported_end,
        "source_provider" => to_string(source_provider(link)),
        "target_provider" => to_string(target_provider(link))
      }
    }

    case CalendarSyncConflictQueries.append(attrs) do
      {:ok, _conflict} ->
        :recorded

      # Swallowed for the reason `ConflictLog` gives: this sits beside a mirror
      # decision that has already been made, and turning a failure to write the
      # audit into a failure of the operation would report a correct refusal as
      # an error the queue then retries.
      {:error, changeset} ->
        Logger.warning("Failed to record an unmirrorable series",
          sync_link_id: link.id,
          source_uid: uid,
          reason: inspect(changeset.errors)
        )

        :nothing_to_record
    end
  end
end
