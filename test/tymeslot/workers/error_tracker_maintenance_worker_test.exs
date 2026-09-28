defmodule Tymeslot.Workers.ErrorTrackerMaintenanceWorkerTest do
  # async: false: the regression test switches ErrorTracker on through its
  # global `enabled` application env and listens to global telemetry.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Ecto.Query
  import Tymeslot.ConfigTestHelpers

  alias Config.Reader
  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Oban.Cron.Expression
  alias Tymeslot.Workers.ErrorTrackerMaintenanceWorker

  describe "perform/1" do
    test "resolves an error last seen longer ago than the window, and deletes it a window later" do
      quiet = insert_error(last_seen_days_ago: 31)
      occurrence = insert_occurrence(quiet, days_ago: 31)

      assert :ok = perform_job()

      # Read the stored column rather than the loaded struct's enum, so a
      # rename of `status` in ErrorTracker's table fails here.
      assert raw_status(quiet) == "resolved"
      assert Repo.get(Occurrence, occurrence.id)

      # A window later: still quiet, so the resolved error goes with its
      # occurrences.
      backdate_last_occurrence(quiet, 61)

      assert :ok = perform_job()

      refute Repo.get(Error, quiet.id)
      refute Repo.get(Occurrence, occurrence.id)
    end

    test "leaves an error seen yesterday unresolved with its occurrences" do
      recent = insert_error(last_seen_days_ago: 1)
      occurrence = insert_occurrence(recent, days_ago: 1)

      assert :ok = perform_job()

      assert raw_status(recent) == "unresolved"
      assert Repo.get(Occurrence, occurrence.id)
    end

    test "resolves a quiet muted error too" do
      muted = insert_error(last_seen_days_ago: 31, muted: true)

      assert :ok = perform_job()

      assert raw_status(muted) == "resolved"
    end

    test "does not delete a resolved error last seen inside the prune window" do
      resolved = insert_error(last_seen_days_ago: 45, status: :resolved)

      assert :ok = perform_job()

      assert Repo.get(Error, resolved.id)
    end

    test "trims an unresolved error's old occurrences to the newest 50, keeping every recent one" do
      error = insert_error(last_seen_days_ago: 0)

      old = for days <- 31..110, do: insert_occurrence(error, days_ago: days)
      recent = for days <- 0..9, do: insert_occurrence(error, days_ago: days)

      untouched_error = insert_error(last_seen_days_ago: 0)
      untouched = for days <- 31..40, do: insert_occurrence(untouched_error, days_ago: days)

      assert :ok = perform_job()

      remaining = remaining_occurrence_ids(error)
      assert length(remaining) == 50

      # The 50 newest of all 90 are the 10 recent ones and the 40 newest old
      # ones (31 to 70 days ago): every recent occurrence survives.
      expected = MapSet.new(recent ++ Enum.take(old, 40), & &1.id)
      assert MapSet.new(remaining) == expected

      assert length(remaining_occurrence_ids(untouched_error)) == length(untouched)
    end

    test "keeps more than 50 occurrences when they are all inside the window" do
      error = insert_error(last_seen_days_ago: 0)
      for _n <- 1..60, do: insert_occurrence(error, days_ago: 2)

      assert :ok = perform_job()

      assert length(remaining_occurrence_ids(error)) == 60
    end
  end

  describe "regression after auto-resolve" do
    setup do
      with_config(:error_tracker, enabled: true)

      handler_id = "error-tracker-maintenance-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:error_tracker, :error, :unresolved],
          fn _event, _measurements, metadata, _config ->
            send(test_pid, {:unresolved, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "a new occurrence of an auto-resolved error is reported as a regression" do
      report_boom()
      assert [error] = Repo.all(Error)
      backdate_last_occurrence(error, 31)

      assert :ok = perform_job()
      assert raw_status(error) == "resolved"

      report_boom()

      assert_receive {:unresolved, %{error: %Error{id: error_id}, occurrence: %Occurrence{}}}
      assert error_id == error.id
      assert raw_status(error) == "unresolved"
    end
  end

  describe "schedule" do
    test "is registered in the runtime crontab with a parseable daily schedule" do
      runtime_exs = "runtime.exs" |> config_path() |> File.read!()

      pattern = ~r/\{\s*"([^"]+)"\s*,\s*Tymeslot\.Workers\.ErrorTrackerMaintenanceWorker\s*\}/

      assert [_match, schedule] = Regex.run(pattern, runtime_exs),
             "ErrorTrackerMaintenanceWorker is not registered in the runtime.exs crontab"

      assert {:ok, _expression} = Expression.parse(schedule)
    end

    test "is registered in the dev crontab" do
      crontab =
        "dev.exs"
        |> config_path()
        |> Reader.read!(env: :dev, target: :host)
        |> get_in([:tymeslot, Oban, :cron, :crontab])

      assert Enum.any?(crontab, &match?({_schedule, ErrorTrackerMaintenanceWorker}, &1))
    end
  end

  defp perform_job, do: ErrorTrackerMaintenanceWorker.perform(%Oban.Job{args: %{}})

  defp config_path(file),
    do: [__DIR__, "..", "..", "..", "config", file] |> Path.join() |> Path.expand()

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp insert_error(opts) do
    Repo.insert!(%Error{
      kind: "Elixir.RuntimeError",
      reason: "boom",
      source_line: "lib/example.ex:#{System.unique_integer([:positive])}",
      source_function: "Example.run/0",
      fingerprint: Base.encode16(:crypto.strong_rand_bytes(16)),
      status: Keyword.get(opts, :status, :unresolved),
      muted: Keyword.get(opts, :muted, false),
      last_occurrence_at: days_ago(Keyword.fetch!(opts, :last_seen_days_ago))
    })
  end

  defp insert_occurrence(%Error{} = error, days_ago: days) do
    Repo.insert!(%Occurrence{
      error_id: error.id,
      reason: "boom",
      context: %{},
      breadcrumbs: [],
      stacktrace: %ErrorTracker.Stacktrace{lines: []},
      inserted_at: days_ago(days)
    })
  end

  defp backdate_last_occurrence(%Error{id: id}, days) do
    {1, _rows} =
      Repo.update_all(from(e in Error, where: e.id == ^id),
        set: [last_occurrence_at: days_ago(days)]
      )
  end

  defp raw_status(%Error{id: id}) do
    %{rows: [[status]]} =
      Repo.query!("SELECT status FROM error_tracker_errors WHERE id = $1", [id])

    status
  end

  defp remaining_occurrence_ids(%Error{id: id}) do
    Repo.all(from o in Occurrence, where: o.error_id == ^id, select: o.id)
  end

  # Raised from one line so both reports share a fingerprint.
  defp report_boom do
    raise "boom"
  rescue
    exception -> ErrorTracker.report(exception, __STACKTRACE__)
  end
end
