defmodule Tymeslot.Workers.CalendarSyncJob do
  @moduledoc """
  The job boundary every calendar sync worker shares.

  A sync worker's `perform/1` hands its job and its cycle to `run/3`, which
  does everything around the cycle that does not depend on the provider:

    * loads the integration named by the job's `calendar_integration_id`,
      discarding the job when it is gone and handing a row that no longer
      decrypts to `Calendar.Management.handle_reauth_required/2`;
    * collects the events the cycle skipped as invalid into one report
      (`Tymeslot.Integrations.Calendar.InvalidEventReport`);
    * bounds the snoozes a cycle uses to wait out an open breaker or a rate
      limit, when the worker names a budget (`Tymeslot.Workers.SnoozePolicy`);
    * discards a cycle that failed because its integration was deleted while
      it ran (`{:error, :integration_gone}` from a cache write, or any failure
      once the row is gone), as a job whose integration is gone at the start
      is, recording nothing against a health state that no longer has an
      integration;
    * records the verdict against the integration's health state
      (`Tymeslot.Workers.SyncHealth`), after the bound, so a cycle that gave
      up waiting counts as the failure it is;
    * runs the job again when a sync was requested while it ran
      (`Tymeslot.Workers.SyncRequest`).

  The cycle itself is the worker's: it takes the integration and returns the
  verdict Oban gets.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.InvalidEventReport
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Workers.SnoozePolicy
  alias Tymeslot.Workers.SyncHealth
  alias Tymeslot.Workers.SyncRequest

  @integration_gone "Integration not found"

  @typedoc "A sync cycle: takes the integration, returns the job's verdict."
  @type cycle :: (CalendarIntegrationSchema.t() -> SyncHealth.verdict())

  @doc "The discard reason of a job whose integration no longer exists."
  @spec integration_gone() :: String.t()
  def integration_gone, do: @integration_gone

  @doc """
  Runs `cycle` for the integration `job` names and returns the job's verdict.

  ## Options

    * `:max_snoozes` — the execution count at which a snooze from `cycle`
      becomes `{:error, reason}`. Required by a cycle that snoozes; without it
      the verdict is not bounded.
    * `:exhausted_reason` — the error reason once `:max_snoozes` is reached.
    * `:provider` — the provider the integration must have. Another provider's
      integration is discarded without running `cycle` or touching its health.
  """
  @spec run(Oban.Job.t(), cycle(), keyword()) :: SyncHealth.verdict()
  def run(
        %Oban.Job{args: %{"calendar_integration_id" => integration_id}} = job,
        cycle,
        opts \\ []
      )
      when is_function(cycle, 1) do
    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        run_cycle(integration, job, cycle, opts)

      {:error, :not_found} ->
        Logger.warning("Calendar integration not found, discarding sync job",
          calendar_integration_id: integration_id,
          worker: job.worker
        )

        {:discard, @integration_gone}

      {:error, :requires_reencryption, integration} ->
        Management.handle_reauth_required(integration)
    end
  end

  defp run_cycle(integration, job, cycle, opts) do
    case Keyword.get(opts, :provider, integration.provider) do
      provider when provider == integration.provider ->
        fn ->
          integration
          |> cycle.()
          |> bound(job, opts)
          |> unless_gone(integration, &SyncHealth.record_outcome(integration, &1))
        end
        |> InvalidEventReport.collect()
        |> SyncRequest.rerun_if_requested(job)

      provider ->
        Logger.warning("Sync job names an integration of another provider, discarding",
          calendar_integration_id: integration.id,
          provider: integration.provider,
          expected_provider: provider,
          worker: job.worker
        )

        {:discard, "Integration is not #{provider}"}
    end
  end

  defp unless_gone(:ok, _integration, record), do: tap(:ok, record)
  defp unless_gone({:snooze, _seconds} = verdict, _integration, record), do: tap(verdict, record)

  defp unless_gone(verdict, integration, record) do
    if verdict == {:error, :integration_gone} or
         not CalendarIntegrationQueries.exists?(integration.id) do
      Logger.info("Calendar integration deleted during its sync, discarding",
        calendar_integration_id: integration.id
      )

      {:discard, @integration_gone}
    else
      tap(verdict, record)
    end
  end

  defp bound(verdict, job, opts) do
    case Keyword.fetch(opts, :max_snoozes) do
      {:ok, max_snoozes} ->
        SnoozePolicy.bound(verdict, job,
          max_snoozes: max_snoozes,
          reason: Keyword.fetch!(opts, :exhausted_reason)
        )

      :error ->
        verdict
    end
  end
end
