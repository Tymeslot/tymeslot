defmodule Tymeslot.Infrastructure.ObanCronTest do
  # `capture_log/1` sees the whole log stream for the duration of its block, so
  # the "stays quiet" assertions here would trip over a concurrently running
  # test's output. Absence assertions on logs mean this module runs alone.
  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Config.Reader
  alias Oban.Cron.Expression
  alias Tymeslot.Infrastructure.ObanCron
  alias Tymeslot.Test.CronUniqueness
  alias Tymeslot.Workers.AdminAlertDigestWorker
  alias Tymeslot.Workers.ErrorTrackerMaintenanceWorker
  alias Tymeslot.Workers.ObanMaintenanceWorker
  alias Tymeslot.Workers.ObanQueueMonitorWorker

  # Unique for seven hours, scheduled at 02:00 and 20:00: the 18-hour gap
  # clears the period, the 6-hour one does not.
  defmodule UnevenlyScheduledWorker do
    use Oban.Worker, unique: [period: 25_200]

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defp config_file(file),
    do: [__DIR__, "..", "..", "..", "config", file] |> Path.join() |> Path.expand()

  defp cron_config(crontab), do: [repo: Tymeslot.Repo, cron: [crontab: crontab]]

  defp all_workers do
    [
      {"*/30 * * * *", ObanMaintenanceWorker},
      {"0 * * * *", ObanQueueMonitorWorker},
      {"5 3 * * *", ErrorTrackerMaintenanceWorker},
      {"0 7 * * *", AdminAlertDigestWorker}
    ]
  end

  # One crontab for dev and production: each environment only switches the
  # cron service on, and the entries are filled in from `:oban_crontab`, so
  # the two cannot drift apart again.
  describe "the shared crontab" do
    test "dev and runtime config switch cron on and leave the entries to it" do
      dev = Reader.read!(config_file("dev.exs"), env: :dev, target: :host)
      assert get_in(dev, [:tymeslot, Oban, :cron]) == []

      # runtime.exs reads the deployment's environment and cannot be
      # evaluated here; its Oban block must not carry a crontab of its own.
      runtime = File.read!(config_file("runtime.exs"))
      assert runtime =~ ~r/^\s*cron: \[\]$/m
      refute runtime =~ ~r/^\s*\{\s*"[^"]+"\s*,\s*Tymeslot\./m
    end

    test "every entry names a loadable worker with a schedule Oban can parse" do
      assert ObanCron.base_crontab() != []

      for entry <- ObanCron.base_crontab() do
        {schedule, worker} = {elem(entry, 0), elem(entry, 1)}
        assert {:ok, _expression} = Expression.parse(schedule), inspect(entry)
        assert Code.ensure_loaded?(worker), inspect(entry)
      end
    end

    test "extend/1 fills the crontab in, Core's entries first" do
      config = ObanCron.extend(repo: Tymeslot.Repo, cron: [])

      assert config[:cron][:crontab] ==
               ObanCron.base_crontab() ++ Application.get_env(:tymeslot, :oban_additional_crontab)

      assert ObanCron.missing_workers(config) == []
    end

    test "no worker's unique period swallows its own next scheduled run" do
      assert CronUniqueness.offenders(ObanCron.base_crontab()) == []
    end

    # The guard must measure the shortest gap, not the first one: from Monday
    # morning, "0 2,20 * * *" first waits 18 hours, but 20:00 to 02:00 is 6.
    test "the guard catches a period that only an uneven schedule's short gap exposes" do
      assert CronUniqueness.shortest_gap("0 2,20 * * *") == 6 * 3600
      assert CronUniqueness.shortest_gap("0 */5 * * *") == 4 * 3600

      assert [{UnevenlyScheduledWorker, 25_200, 21_600}] =
               CronUniqueness.offenders([{"0 2,20 * * *", UnevenlyScheduledWorker}])
    end

    test "carries the entries byte for byte, args included" do
      assert {"0 4 * * *", Tymeslot.Workers.DataRetentionWorker, args: %{retention_days: 60}} in ObanCron.base_crontab()

      assert {"15 3 * * *", Tymeslot.Workers.ExpiredSessionCleanupWorker} in ObanCron.base_crontab()
    end
  end

  # The extension point a wrapper application schedules its own periodic
  # workers through: without it they can only re-insert their own next run,
  # a chain that one crash ends for good.
  describe "extend/2" do
    test "appends the additional entries to the crontab" do
      extra = [{"0 2 * * *", ObanMaintenanceWorker, args: %{"extra" => true}}]

      config = ObanCron.extend(cron_config(all_workers()), extra)

      assert config[:cron][:crontab] == all_workers() ++ extra
    end

    test "extends a crontab given as a {module, opts} plugin tuple" do
      extra = [{"0 2 * * *", ObanMaintenanceWorker}]
      config = [cron: {Oban.Plugins.Cron, crontab: all_workers()}]

      assert {Oban.Plugins.Cron, opts} = ObanCron.extend(config, extra)[:cron]
      assert opts[:crontab] == all_workers() ++ extra
    end

    test "leaves a configuration without a cron service as it is" do
      config = [repo: Tymeslot.Repo, testing: :manual]

      assert ObanCron.extend(config, [{"0 2 * * *", ObanMaintenanceWorker}]) == config
    end

    test "rejects an additional crontab that is not a list" do
      assert_raise ArgumentError, fn ->
        ObanCron.extend(cron_config(all_workers()), {"0 2 * * *", ObanMaintenanceWorker})
      end
    end
  end

  describe "missing_workers/1" do
    test "finds nothing missing when the crontab schedules every critical worker" do
      assert ObanCron.missing_workers(cron_config(all_workers())) == []
    end

    test "reads a crontab entry that carries its own options" do
      crontab =
        Enum.map(all_workers(), fn {schedule, worker} -> {schedule, worker, args: %{}} end)

      assert ObanCron.missing_workers(cron_config(crontab)) == []
    end

    test "names the worker the crontab leaves out" do
      crontab = List.delete(all_workers(), {"0 * * * *", ObanQueueMonitorWorker})

      assert ObanCron.missing_workers(cron_config(crontab)) == [ObanQueueMonitorWorker]
    end

    # Without them, resolved errors are never pruned and info alerts never
    # reach the operator, and neither failure makes a sound of its own.
    test "counts the error tracking and alert digest workers as critical" do
      crontab = [
        {"*/30 * * * *", ObanMaintenanceWorker},
        {"0 * * * *", ObanQueueMonitorWorker}
      ]

      assert ObanCron.missing_workers(cron_config(crontab)) ==
               [ErrorTrackerMaintenanceWorker, AdminAlertDigestWorker]
    end

    test "reads the {module, opts} form of the cron service" do
      config = [cron: {Oban.Cron, crontab: all_workers()}]

      assert ObanCron.missing_workers(config) == []
    end

    test "reports no crontab when the cron service is absent or switched off" do
      assert ObanCron.missing_workers(repo: Tymeslot.Repo) == :no_crontab
      assert ObanCron.missing_workers(cron: false) == :no_crontab
      assert ObanCron.missing_workers(cron: Oban.Cron) == :no_crontab
    end

    # This check reads the raw application environment, so it is coupled to the
    # shape the config is written in. Oban 2.24 hoisted the crontab out of
    # `plugins:` and into `cron:`; a config left on the old shape reports as
    # having no crontab at all, which is precisely the silent failure this
    # pairing has to be tested for rather than assumed.
    test "does not find a crontab left behind in the pre-2.24 plugins list" do
      config = [plugins: [{Oban.Plugins.Cron, crontab: all_workers()}]]

      assert ObanCron.missing_workers(config) == :no_crontab
    end
  end

  # This module reads the raw application environment, so it is only ever as
  # good as its agreement with the config files: the config file is where a
  # rename lands, and this module is where that rename gets missed. Reading the
  # real config back and validating it is what stops the two drifting apart in
  # silence. `runtime.exs` cannot be read this way (it wants the production
  # environment), but it switches cron on with the same shape as dev, and the
  # entries come from the one shared crontab either way.
  describe "the project's own configuration" do
    test "schedules every critical worker in a shape this module can read" do
      config =
        [__DIR__, "..", "..", "..", "config", "dev.exs"]
        |> Path.join()
        |> Path.expand()
        |> Reader.read!(env: :dev, target: :host)
        |> get_in([:tymeslot, Oban])
        |> ObanCron.extend()

      assert ObanCron.missing_workers(config) == []
    end
  end

  describe "warn_on_missing_workers/1" do
    test "stays quiet when every critical worker is scheduled" do
      log =
        capture_log(fn ->
          assert :ok = ObanCron.warn_on_missing_workers(cron_config(all_workers()))
        end)

      refute log =~ "Critical Oban worker"
      refute log =~ "OBAN CRON SERVICE NOT CONFIGURED"
    end

    test "names each unscheduled worker" do
      crontab = List.delete(all_workers(), {"*/30 * * * *", ObanMaintenanceWorker})

      log = capture_log(fn -> ObanCron.warn_on_missing_workers(cron_config(crontab)) end)

      assert log =~ "Critical Oban worker not scheduled"
      assert log =~ "ObanMaintenanceWorker"
      refute log =~ "ObanQueueMonitorWorker."
    end

    test "warns once about the service itself when there is no crontab" do
      log = capture_log(fn -> ObanCron.warn_on_missing_workers(repo: Tymeslot.Repo) end)

      assert log =~ "OBAN CRON SERVICE NOT CONFIGURED"
      assert log =~ "critical maintenance workers will not run"
    end
  end
end
