defmodule Tymeslot.Integrations.Calendar.InvalidEventReport do
  @moduledoc """
  Gathers the calendar events a sync run had to skip as malformed, and raises
  one `:invalid_calendar_event` operator alert per integration for the run.

  The provider normalisers used to alert once per bad event, from inside the
  normalise loop. A feed carrying N malformed events therefore made N
  synchronous alert inserts (each with its own uniqueness query) in the middle
  of a sync, only for all but the first to be deduplicated away. The
  normalisers now `record/4` each skip instead, and the sync entry point
  wraps its run in `collect/1`, which sends the batch once the run ends.

  ## Why the process dictionary

  `normalise_events/2` is a `Provider` callback returning
  `{:ok, [CalendarEvent.t()]}`, consumed by every sync worker, the delta and
  webhook paths, diagnostics and the single-event fetches after a move.
  Widening that contract to carry the skips out would touch all of them to
  deliver data only the sync workers act on. Recording into the calling
  process keeps the contract, and every normaliser runs in the process of the
  worker that called it (the CalDAV fetch tasks only fetch; normalising happens
  back in the caller).

  A `record/4` outside `collect/1` is a no-op: the normaliser's own warning
  log still carries the skip. That is deliberate for the non-sync callers
  (diagnostics, which reports to the user directly, and the single-event
  fetches, whose event the next sync reads again).

  ## What the alert carries

  `count` is every skip of the run; `sample_events` names the first
  five as `id (reason)`, rendered to one string so the PII sweep of free-form
  strings covers it. The alert's `reason` is the most common reason in the
  run, ties broken by the alphabetically first so the dedup key stays stable
  across runs; `reasons` lists all distinct reasons. The dedup key is
  provider, integration and that most common reason, so a feed that keeps
  producing the same bad events alerts once per window, while a new failure
  mode on the same integration alerts again.
  """

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.ReasonNormaliser

  @key {__MODULE__, :batches}
  @max_samples 5

  @doc """
  Runs `fun`, collecting every `record/4` it makes, then raises one alert per
  provider and integration with skips. Returns `fun`'s result.

  Nested calls join the outermost collection, so a run is reported once
  however its entry points are layered. The batch is still reported if `fun`
  raises, since the events it skipped before raising were skipped all the
  same.
  """
  @spec collect((-> result)) :: result when result: term()
  def collect(fun) when is_function(fun, 0) do
    if Process.get(@key) do
      fun.()
    else
      Process.put(@key, %{})

      try do
        fun.()
      after
        @key |> Process.delete() |> Enum.each(&report/1)
      end
    end
  end

  @doc """
  Records one skipped event against the open collection, if there is one.

  `context` is the normalisation context and must carry
  `:calendar_integration_id`. `event_id` is whatever identifier the provider
  has (a Graph id, a UID); `nil` is recorded as `"unknown"`.
  """
  @spec record(atom(), %{calendar_integration_id: term()}, term(), term()) :: :ok
  def record(provider, %{calendar_integration_id: integration_id}, event_id, reason) do
    case Process.get(@key) do
      nil ->
        :ok

      batches ->
        skip = {to_string(event_id || "unknown"), reason_message(reason)}
        batches = Map.update(batches, {provider, integration_id}, new_batch(skip), &add(&1, skip))
        Process.put(@key, batches)
        :ok
    end
  end

  defp new_batch({_id, reason} = skip),
    do: %{count: 1, samples: [skip], reasons: %{reason => 1}}

  defp add(batch, {_id, reason} = skip) do
    %{
      count: batch.count + 1,
      samples: if(batch.count < @max_samples, do: [skip | batch.samples], else: batch.samples),
      reasons: Map.update(batch.reasons, reason, 1, &(&1 + 1))
    }
  end

  defp report({{provider, integration_id}, batch}) do
    AdminAlerts.report(:invalid_calendar_event,
      summary: "#{batch.count} invalid #{provider} calendar event(s) skipped",
      reason: most_common_reason(batch.reasons),
      context: %{
        provider: provider,
        calendar_integration_id: integration_id,
        count: batch.count,
        reasons: batch.reasons |> Map.keys() |> Enum.sort() |> Enum.join("; "),
        sample_events:
          batch.samples
          |> Enum.reverse()
          |> Enum.map_join("; ", fn {id, reason} -> "#{id} (#{reason})" end)
      }
    )
  end

  defp most_common_reason(reasons) do
    {reason, _count} = Enum.min_by(reasons, fn {reason, count} -> {-count, reason} end)
    reason
  end

  defp reason_message(reason) do
    case ReasonNormaliser.normalise(reason) do
      nil -> "unknown"
      %{message: message} -> message
    end
  end
end
