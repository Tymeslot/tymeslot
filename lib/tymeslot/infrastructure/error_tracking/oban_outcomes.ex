defmodule Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes do
  @moduledoc """
  Records the Oban jobs that end without running to completion and without
  raising, which ErrorTracker's own Oban integration never sees, and the jobs
  that fail, in that integration's place (see *Failed jobs* below).

  That integration listens to `[:oban, :job, :exception]` only: a job that
  raises, returns `{:error, reason}` or times out, including the final
  attempt that Oban then discards. Three other ways a job can end leave no
  trace there:

    * The worker returns `{:discard, reason}` or `{:cancel, reason}`. Oban
      reports that as `[:oban, :job, :stop]` with state `:discard` or
      `:cancelled`. This module records it through
      `Tymeslot.Infrastructure.ErrorTracking.report_error/3`, as a
      `Tymeslot.Infrastructure.ErrorTracking.JobDiscardedError`, unless the
      worker declares the outcome expected (below). Oban reports a job
      outcome as either `:stop` or `:exception`, never both, so no job
      outcome is recorded twice.
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
  deliveries). A worker says so by implementing
  `Tymeslot.Infrastructure.ExpectedJobOutcome`, next to the code that
  returns the reason. The job's worker is resolved from its name without
  creating atoms; when it does not export `expected_outcome?/1`, or the
  callback raises or returns anything but `true`, the outcome is recorded.

  ## Grouping

  ErrorTracker groups occurrences by exception kind and source frame, and a
  discard has no stacktrace. The recorded frame is therefore synthetic: the
  worker's `perform/1`, with the outcome and the reason's leading text as its
  file and line 0. So each worker and reason is one error, while the detail
  after a reason's first `": "` (an HTTP status line, a provider message)
  stays in the message and does not split it.

  ## Failed jobs

  A job that raises, returns `{:error, reason}`, times out or is killed is
  reported as `[:oban, :job, :exception]`. ErrorTracker's integration records
  it with the `job.*` context its `:start` handler put in the job's process.
  A timeout or a crash of a linked process is reported from a fresh task
  under Oban's foreman instead, which has no such context: the occurrence
  would carry no job id, and an alert about a failing admin alert email
  could not be recognised as one. `report_exception/1` therefore builds the
  `job.*` context from the job itself and passes it with the report.
  `Tymeslot.Infrastructure.ErrorTracking.SafeIntegrations` calls it in place
  of the integration's own handler.

  Telemetry detaches a handler that raises, so `handle_event/4` never raises:
  a failure is logged, naming only its module, and dropped.
  """

  alias Oban.Worker
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ErrorTracking.HandledError
  alias Tymeslot.Infrastructure.ErrorTracking.JobDiscardedError
  alias Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Jobs

  require Logger

  @handler_id "tymeslot-error-tracking-oban-outcomes"

  @events [
    [:oban, :job, :stop],
    [:oban, :plugin, :stop]
  ]

  @max_label_length 80
  @unknown_worker "unknown worker"

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

  @doc """
  Records the job failure reported by an `[:oban, :job, :exception]` event,
  as ErrorTracker's Oban integration does, but with the job's context taken
  from `metadata.job` rather than from the reporting process. Raises when the
  report fails; the caller guards against that.
  """
  @spec report_exception(map()) :: :ok
  def report_exception(%{job: %Oban.Job{} = job, reason: reason} = metadata) do
    state = Map.get(metadata, :state, :failure)
    exception = if is_exception(reason), do: reason, else: {Map.get(metadata, :kind), reason}

    _occurrence =
      ErrorTracker.report(
        exception,
        failure_stacktrace(job.worker, Map.get(metadata, :stacktrace)),
        Map.put(job_context(job), :state, state)
      )

    :ok
  end

  # ErrorTracker's integration uses the same synthetic frame, so an error
  # returned from a worker keeps the fingerprint it had before.
  defp failure_stacktrace(worker, [_frame | _more] = stacktrace) when is_binary(worker),
    do: stacktrace

  defp failure_stacktrace(worker, _none), do: [{worker_module(worker), :perform, 2, []}]

  # The keys ErrorTracker's Oban integration sets when the job starts, plus
  # the attempt limit `Tymeslot.Infrastructure.ObanLogger` adds.
  defp job_context(%Oban.Job{} = job) do
    %{
      "job.args" => job.args,
      "job.attempt" => job.attempt,
      "job.id" => job.id,
      "job.max_attempts" => job.max_attempts,
      "job.priority" => job.priority,
      "job.queue" => job.queue,
      "job.worker" => job.worker
    }
  end

  @doc false
  @spec handle_event([atom()], map(), map(), term()) :: :ok
  def handle_event(
        [:oban, :job, :stop],
        _measurements,
        %{state: state, job: %Oban.Job{worker: worker} = job, result: result},
        _config
      )
      when state in [:discard, :cancelled] do
    outcome = if state == :discard, do: :discard, else: :cancel
    reason = result_reason(result)

    if not expected?(worker, reason), do: record(job, outcome, reason)

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

  Each job needs `:id` and `:queue`. `Oban.Lifeline` reports plain maps of
  `:id`, `:queue` and `:state`, so a job without `:worker` has it looked up
  by id; one whose row is gone by then, or when the lookup fails, is counted
  as an unknown worker in its queue.
  """
  @spec report_force_discarded([map()], module()) :: :ok
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
    workers = workers(jobs)

    jobs
    |> Enum.frequencies_by(&{Map.get(workers, &1.id, @unknown_worker), &1.queue})
    |> Enum.sort()
    |> Enum.map_join("; ", fn {{worker, queue}, count} -> "#{worker} (#{queue}): #{count}" end)
  end

  defp workers(jobs) do
    {known, unknown} = Enum.split_with(jobs, &is_binary(Map.get(&1, :worker)))
    known = Map.new(known, &{&1.id, &1.worker})

    case Enum.map(unknown, & &1.id) do
      [] -> known
      ids -> Map.merge(lookup_workers(ids), known)
    end
  end

  # The alert is worth more with the queues alone than not at all.
  defp lookup_workers(ids) do
    Jobs.workers_by_id(ids)
  rescue
    exception ->
      Logger.error("Could not look up the workers of force-discarded jobs",
        error: LogFormat.reason(exception.__struct__)
      )

      %{}
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
    case Worker.from_string(worker) do
      {:ok, module} -> declared_expected?(module, reason)
      {:error, _unknown} -> false
    end
  end

  defp declared_expected?(module, reason) do
    function_exported?(module, :expected_outcome?, 1) and module.expected_outcome?(reason) == true
  rescue
    exception -> callback_failed(module, inspect(exception.__struct__))
  catch
    kind, _reason -> callback_failed(module, inspect(kind))
  end

  # A broken callback must not hide the outcome it was asked about.
  defp callback_failed(module, error) do
    Logger.error("Expected outcome check failed; recording the outcome",
      worker: LogFormat.reason(module),
      error: error
    )

    false
  end

  # A job cancelled by a shutdown is reported from outside its process, so
  # the job's context is passed along here too.
  defp record(%Oban.Job{worker: worker} = job, outcome, reason) do
    exception = JobDiscardedError.exception({worker, outcome, reason})

    ErrorTracking.report_error(
      exception,
      stacktrace(worker, outcome, reason),
      Map.merge(job_context(job), %{
        job_outcome: Atom.to_string(outcome),
        job_reason: exception.reason
      })
    )
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
    |> normalise_values()
    |> String.slice(0, @max_label_length)
    |> ReasonScrubber.scrub()
  end

  defp group_label(reason) when is_atom(reason), do: inspect(reason)
  defp group_label(reason), do: HandledError.exception(reason).message

  defp normalise_values(text) do
    Enum.reduce(label_placeholders(), text, fn {pattern, placeholder}, acc ->
      Regex.replace(pattern, acc, placeholder)
    end)
  end

  # Variable values a reason may interpolate without a colon, replaced in the
  # error's group label so each value does not mint a new error. Most specific
  # first: a timestamp or UUID would otherwise be eaten as digit runs.
  # A function rather than an attribute: compiled regexes cannot be stored
  # in module attributes.
  defp label_placeholders do
    [
      {~r/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?/, "<time>"},
      {~r/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/,
       "<uuid>"},
      {~r/\b(?=[0-9a-fA-F]*\d)(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{8,}\b/, "<hex>"},
      {~r/\d+/, "<n>"}
    ]
  end

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
