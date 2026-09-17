defmodule Tymeslot.Workers.SyncHealth do
  @moduledoc """
  Feeds each calendar sync job's verdict into integration health state.

  A failed sync is the only evidence some outages produce. The scheduled probe
  and a sync do not issue the same request, so a server can answer one while
  refusing the other; when that happens the probe is honestly healthy and the
  integration silently stops syncing behind a green badge.
  `Tymeslot.Integrations.HealthCheck.record_sync_failure/2` is what closes that
  gap, and this module is the single place deciding which verdict earns it, so
  the five calendar sync workers cannot drift apart on the question.

  ## Call it once, at the job boundary

  Both halves belong on the verdict a worker is about to hand Oban, so that
  they measure the same thing: one attempt at one sync cycle, succeeded or
  failed. Recording success anywhere deeper counts something smaller than a
  cycle — the Google worker used to clear the streak while persisting the sync
  token, before its secondary calendars had been read at all, so an
  integration whose second calendar failed every time could never build a
  streak and its badge stayed green through an indefinite outage.

  One attempt, not one job: a retried job records once per attempt, which is
  what makes a cycle that exhausts its retries weigh more than one that fails
  once.
  """

  alias Tymeslot.Integrations.HealthCheck

  @typedoc "The verdict a sync worker's `perform/1` returns to Oban."
  @type verdict :: :ok | {:snooze, pos_integer()} | {:discard, term()} | {:error, term()}

  @doc """
  Records `verdict` against `integration`'s calendar health state.

  Returns `:ok` whatever the verdict, so it can be dropped into a pipeline
  with `tap/2` without altering what the worker returns.
  """
  @spec record_outcome(map(), verdict()) :: :ok
  def record_outcome(integration, verdict)

  def record_outcome(integration, :ok),
    do: HealthCheck.mark_synced_successfully(:calendar, integration.id)

  # A snooze is the host's circuit breaker declining to place the call, not the
  # remote declining to answer it — nothing was sent and nothing about this
  # integration was learnt. The breaker is keyed by provider rather than by
  # integration, so one account's outage opens it for every account on that
  # provider, and counting the refusal would spread one integration's failures
  # across everyone else's badges. The failures that opened it were counted
  # where they happened.
  def record_outcome(_integration, {:snooze, _seconds}), do: :ok

  # Everything else is a cycle that did not sync: `{:error, _}` on its way to
  # an Oban retry, and the deliberate `{:discard, _}` for failures no retry
  # could help. The discards matter most — they emit `job:stop`, which
  # `ObanFailureAlerter` ignores, so the streak is the only thing that makes
  # their quietness temporary. Reasons that also flag the integration for
  # reconnection simply reach the badge by two routes, which
  # `record_sync_failure/2` documents as safe.
  def record_outcome(integration, _failure),
    do: HealthCheck.record_sync_failure(:calendar, integration)
end
