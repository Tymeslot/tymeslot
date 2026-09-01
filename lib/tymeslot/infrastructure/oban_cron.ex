defmodule Tymeslot.Infrastructure.ObanCron do
  @moduledoc """
  Checks the `:cron` section of the Oban configuration for the maintenance
  workers the system depends on.

  `Tymeslot.Workers.ObanMaintenanceWorker` and
  `Tymeslot.Workers.ObanQueueMonitorWorker` run from the crontab and nowhere
  else. Without them jobs accumulate and queue problems go unreported, and
  nothing else notices they are gone, so startup says so loudly rather than
  degrading in silence.

  The check reads the raw application environment rather than Oban's own
  normalised state, so it has to know the shapes `:cron` accepts: a keyword
  list, a `{module, opts}` tuple, a bare module, or `false` to disable the
  service outright. Only the first two can carry a crontab of ours.
  """

  require Logger

  @critical_workers [
    Tymeslot.Workers.ObanMaintenanceWorker,
    Tymeslot.Workers.ObanQueueMonitorWorker
  ]

  @doc """
  The critical workers `oban_config` fails to schedule.

  `:no_crontab` means the `:cron` service itself is absent or disabled, which
  costs every critical worker at once and is worth reporting as its own thing.
  """
  @spec missing_workers(keyword()) :: [module()] | :no_crontab
  def missing_workers(oban_config) do
    case crontab(Keyword.get(oban_config, :cron)) do
      nil -> :no_crontab
      crontab -> Enum.reject(@critical_workers, &scheduled?(crontab, &1))
    end
  end

  @doc """
  Logs a warning for each critical worker `oban_config` does not schedule.
  """
  @spec warn_on_missing_workers(keyword()) :: :ok
  def warn_on_missing_workers(oban_config) do
    oban_config
    |> missing_workers()
    |> warn()
  end

  defp warn(:no_crontab) do
    Logger.warning(
      """
      OBAN CRON SERVICE NOT CONFIGURED:
      Oban's `cron:` service is missing or disabled, so it carries no crontab.
      The critical maintenance workers will not run, which leads to job
      accumulation and queue problems going unreported. Add
      `cron: [crontab: [...]]` to the Oban config with the required jobs.
      """,
      critical_workers: inspect(@critical_workers)
    )
  end

  defp warn(missing_workers) do
    Enum.each(missing_workers, fn worker ->
      Logger.warning(
        "Critical Oban worker not scheduled in the cron service: #{inspect(worker)}. " <>
          "This worker should run periodically for system health."
      )
    end)
  end

  defp crontab({_module, opts}) when is_list(opts), do: Keyword.get(opts, :crontab)
  defp crontab(opts) when is_list(opts), do: Keyword.get(opts, :crontab)

  # Absent, `false`, or an alternative implementation named as a bare module:
  # no crontab of ours to read.
  defp crontab(_other), do: nil

  defp scheduled?(crontab, worker) do
    Enum.any?(crontab, fn
      {_schedule, ^worker} -> true
      {_schedule, ^worker, _opts} -> true
      _other -> false
    end)
  end
end
