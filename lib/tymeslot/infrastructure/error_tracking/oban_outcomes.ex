defmodule Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes do
  @moduledoc """
  Records the Oban jobs that end without running to completion and without
  raising, which ErrorTracker's own Oban integration never sees.

  That integration listens to `[:oban, :job, :exception]` only: a job that
  raises, returns `{:error, reason}` or times out, including the final
  attempt that Oban then discards. Three other ways a job can end leave no
  trace there:

    * The worker returns `{:discard, reason}` or `{:cancel, reason}`. Oban
      reports that as `[:oban, :job, :stop]` with state `:discard` or
      `:cancelled`. This module records it through
      `Tymeslot.Infrastructure.ErrorTracking.report_error/3`, as a
      `Tymeslot.Infrastructure.ErrorTracking.JobDiscarded`, unless the
      outcome is on the expected list (below). Because the integration
      ignores `:stop` and this module ignores `:exception`, no job outcome is
      recorded by both.
    * `Oban.Lifeline` discards an `executing` job that has used up its
      attempts, reported as `[:oban, :plugin, :stop]` with the jobs in
      `discarded_jobs`.
    * `Tymeslot.Workers.ObanMaintenanceWorker` moves a stuck job straight to
      `discarded`, which emits no telemetry at all; it calls
      `report_force_discarded/2` itself.

  The last two raise one `:oban_jobs_force_discarded` admin alert per sweep
  rather than an error each: no code failed, so there is no call site to
  group by, and the operator needs the count per worker and queue.

  ## Expected outcomes

  Most discards are a worker recognising that its work no longer applies (the
  meeting was deleted, the integration disconnected) or that only the user
  can fix it (credentials to reconnect, a webhook endpoint refusing
  deliveries). `config :tymeslot, :expected_job_outcomes` lists them, as a
  keyword list of worker module (or `:any_worker`) to the reasons expected
  from it. A reason is matched by equality, or by `{:prefix, text}` for a
  reason that carries a variable tail. The list is a keyword list so that a
  deployment's config can add its own workers' entries: `config/3` deep
  merges keyword lists.

  ## Grouping

  ErrorTracker groups occurrences by exception kind and source frame, and a
  discard has no stacktrace. The recorded frame is therefore synthetic: the
  worker's `perform/1`, with the outcome and the reason's leading text as its
  file and line 0. So each worker and reason is one error, while the detail
  after a reason's first `": "` (an HTTP status line, a provider message)
  stays in the message and does not split it.

  Telemetry detaches a handler that raises, so `handle_event/4` never raises:
  a failure is logged, naming only its module, and dropped.
  """

  alias Oban.Worker
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ErrorTracking.HandledError
  alias Tymeslot.Infrastructure.ErrorTracking.JobDiscarded
  alias Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber

  require Logger

  @handler_id "tymeslot-error-tracking-oban-outcomes"

  @events [
    [:oban, :job, :stop],
    [:oban, :plugin, :stop]
  ]

  @max_label_length 80
  @max_listed_job_ids 20

  @doc """
  Attaches the telemetry handler. Idempotent, so safe to call on
  application restart inside the same BEAM.
  """
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    detach()
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc "Detaches the telemetry handler, if attached."
  @spec detach() :: :ok
  def detach do
    _detached = :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(
        [:oban, :job, :stop],
        _measurements,
        %{state: state, job: %Oban.Job{worker: worker}, result: result},
        _config
      )
      when state in [:discard, :cancelled] do
    outcome = if state == :discard, do: :discard, else: :cancel
    reason = result_reason(result)

    if not expected?(worker, reason), do: record(worker, outcome, reason)

    :ok
  rescue
    exception -> log_failure(inspect(exception.__struct__))
  catch
    kind, _reason -> log_failure(inspect(kind))
  end

  def handle_event(
        [:oban, :plugin, :stop],
        _measurements,
        %{plugin: Oban.Lifeline, discarded_jobs: [_job | _more] = jobs},
        _config
      ) do
    report_force_discarded(jobs, Oban.Lifeline)
  rescue
    exception -> log_failure(inspect(exception.__struct__))
  catch
    kind, _reason -> log_failure(inspect(kind))
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @doc """
  Raises one `:oban_jobs_force_discarded` alert for `jobs`, discarded by
  `discarded_by` without their worker returning: the count, the jobs per
  worker and queue, and the first job ids. Does nothing for an empty list.
  """
  @spec report_force_discarded([Oban.Job.t()], module()) :: :ok
  def report_force_discarded([], _discarded_by), do: :ok

  def report_force_discarded(jobs, discarded_by) when is_list(jobs) do
    _result =
      AdminAlerts.report(:oban_jobs_force_discarded,
        summary: "Jobs discarded without running to completion",
        context: %{
          count: length(jobs),
          discarded_by: inspect(discarded_by),
          jobs: per_worker_and_queue(jobs),
          job_ids: job_ids(jobs)
        }
      )

    :ok
  end

  defp per_worker_and_queue(jobs) do
    jobs
    |> Enum.frequencies_by(&{&1.worker, &1.queue})
    |> Enum.sort()
    |> Enum.map_join("; ", fn {{worker, queue}, count} -> "#{worker} (#{queue}): #{count}" end)
  end

  defp job_ids(jobs) do
    ids = jobs |> Enum.map(& &1.id) |> Enum.sort()
    listed = ids |> Enum.take(@max_listed_job_ids) |> Enum.join(", ")

    case length(ids) - @max_listed_job_ids do
      more when more > 0 -> "#{listed} and #{more} more"
      _none -> listed
    end
  end

  defp result_reason({outcome, reason}) when outcome in [:discard, :cancel], do: reason
  defp result_reason(_bare_discard), do: nil

  defp expected?(worker, reason) do
    :tymeslot
    |> Application.get_env(:expected_job_outcomes, [])
    |> Enum.any?(fn {scope, reasons} ->
      applies_to?(scope, worker) and Enum.any?(reasons, &matches?(&1, reason))
    end)
  end

  defp applies_to?(:any_worker, _worker), do: true
  defp applies_to?(module, worker), do: inspect(module) == worker

  defp matches?({:prefix, prefix}, reason) when is_binary(reason),
    do: String.starts_with?(reason, prefix)

  defp matches?({:prefix, _prefix}, _reason), do: false
  defp matches?(expected, reason), do: expected == reason

  defp record(worker, outcome, reason) do
    exception = JobDiscarded.exception({worker, outcome, reason})

    ErrorTracking.report_error(exception, stacktrace(worker, outcome, reason), %{
      job_outcome: Atom.to_string(outcome),
      job_reason: exception.reason
    })
  end

  defp stacktrace(worker, outcome, reason) do
    file = String.to_charlist("#{outcome}: #{group_label(reason)}")
    [{worker_module(worker), :perform, 1, [file: file, line: 0]}]
  end

  # The part of the reason that names the failure, never the detail after it.
  # Masked, since it is stored as the error's source, which nothing rewrites.
  defp group_label(reason) when is_binary(reason) do
    reason
    |> String.split(": ", parts: 2)
    |> hd()
    |> String.slice(0, @max_label_length)
    |> ReasonScrubber.scrub()
  end

  defp group_label(reason) when is_atom(reason), do: inspect(reason)
  defp group_label(reason), do: HandledError.exception(reason).message

  defp worker_module(worker) do
    case Worker.from_string(worker) do
      {:ok, module} -> module
      {:error, _reason} -> __MODULE__
    end
  end

  defp log_failure(error) do
    Logger.error("Failed to record a discarded or cancelled Oban job", error: error)
    :ok
  end
end
