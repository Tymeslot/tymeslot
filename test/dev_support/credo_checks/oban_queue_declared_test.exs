Code.require_file(
  "dev_support/credo_checks/oban_queue_declared.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.ObanQueueDeclaredTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.ObanQueueDeclared

  @moduletag :dev_support

  # The check reads real config files by default. Tests pass `queue_names`
  # to bypass that discovery entirely and assert against a fixed set, so
  # they stay deterministic regardless of what config/config.exs happens to
  # declare. The fail-open path is exercised separately, by pointing
  # `config_paths` at files that do not exist.
  @queue_names [:emails, :webhooks]

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags a queue that is not in the configured set" do
      """
      defmodule Tymeslot.Workers.WeeklyReportWorker do
        use Oban.Worker, queue: :report

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("lib/tymeslot/workers/weekly_report_worker.ex")
      |> run_check(ObanQueueDeclared, queue_names: @queue_names)
      |> assert_issue(fn issue -> assert issue.trigger == "queue: :report" end)
    end

    test "flags an unconfigured queue alongside other use options" do
      """
      defmodule Tymeslot.Workers.WeeklyReportWorker do
        use Oban.Worker, queue: :report, max_attempts: 3

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("lib/tymeslot/workers/weekly_report_worker.ex")
      |> run_check(ObanQueueDeclared, queue_names: @queue_names)
      |> assert_issue()
    end
  end

  describe "accepted cases" do
    test "accepts a queue that is in the configured set" do
      """
      defmodule Tymeslot.Workers.ReminderEmailWorker do
        use Oban.Worker, queue: :emails, max_attempts: 5

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("lib/tymeslot/workers/reminder_email_worker.ex")
      |> run_check(ObanQueueDeclared, queue_names: @queue_names)
      |> refute_issues()
    end

    test "ignores a non-literal queue value" do
      """
      defmodule Tymeslot.Workers.DynamicQueueWorker do
        @queue :report

        use Oban.Worker, queue: @queue

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("lib/tymeslot/workers/dynamic_queue_worker.ex")
      |> run_check(ObanQueueDeclared, queue_names: @queue_names)
      |> refute_issues()
    end

    test "ignores files outside lib/" do
      """
      defmodule Tymeslot.Workers.WeeklyReportWorkerTest do
        use Oban.Worker, queue: :report

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("test/tymeslot/workers/weekly_report_worker_test.exs")
      |> run_check(ObanQueueDeclared, queue_names: @queue_names)
      |> refute_issues()
    end

    test "fails open when no config file can be read" do
      """
      defmodule Tymeslot.Workers.WeeklyReportWorker do
        use Oban.Worker, queue: :report

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("lib/tymeslot/workers/weekly_report_worker.ex")
      |> run_check(ObanQueueDeclared,
        config_paths: ["nonexistent/config.exs", "also/nonexistent/config.exs"]
      )
      |> refute_issues()
    end
  end

  # Every test above overrides discovery, so none of them would notice if the
  # default path ever stopped finding anything. Because the check fails open,
  # that regression is silent: it would simply stop enforcing, with no error.
  # These two run with no params at all, against the repo's real config.exs,
  # so moving :oban_queues into runtime.exs or reformatting the declaration to
  # the two-argument `config :tymeslot, oban_queues: [...]` form breaks the
  # suite instead of quietly disabling the check.
  describe "discovery against the real config" do
    test "finds the queues declared in config/config.exs" do
      """
      defmodule Tymeslot.Workers.ReminderEmailWorker do
        use Oban.Worker, queue: :emails

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("lib/tymeslot/workers/reminder_email_worker.ex")
      |> run_check(ObanQueueDeclared)
      |> refute_issues()
    end

    test "still flags an undeclared queue when reading the real config" do
      """
      defmodule Tymeslot.Workers.WeeklyReportWorker do
        use Oban.Worker, queue: :definitely_not_a_configured_queue

        def perform(_job), do: :ok
      end
      """
      |> to_source_file("lib/tymeslot/workers/weekly_report_worker.ex")
      |> run_check(ObanQueueDeclared)
      |> assert_issue()
    end
  end
end
