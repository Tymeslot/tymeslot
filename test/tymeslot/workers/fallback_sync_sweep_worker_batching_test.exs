defmodule Tymeslot.Workers.FallbackSyncSweepWorkerBatchingTest do
  @moduledoc """
  The fallback sweep reads integrations as a stream and decides and enqueues
  them one batch at a time, so it holds one batch in memory however many
  integrations there are, and paces the batches a second apart.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Workers.FallbackSyncSweepWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  describe "perform/1 - batching" do
    # One batch of the stream is decided and enqueued before the next is
    # read, and each batch after the first is scheduled a second later.
    test "enqueues every due integration past one batch, the second batch a second later" do
      integrations =
        for _n <- 1..51, do: insert(:calendar_integration, provider: "google", is_active: true)

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      jobs = all_enqueued(worker: SyncGoogleCalendarWorker)

      assert jobs |> Enum.map(& &1.args["calendar_integration_id"]) |> Enum.sort() ==
               integrations |> Enum.map(& &1.id) |> Enum.sort()

      # The first batch is scheduled as inserted; the second, one integration,
      # a second after the sweep started.
      earliest = jobs |> Enum.map(& &1.scheduled_at) |> Enum.min(DateTime)

      staggered =
        Enum.filter(jobs, &(DateTime.diff(&1.scheduled_at, earliest, :millisecond) >= 900))

      assert [%{args: %{"calendar_integration_id" => last_id}}] = staggered
      assert last_id == integrations |> Enum.map(& &1.id) |> Enum.max()
    end
  end

  # An insert made inside a transaction holds Oban's unique lock until that
  # transaction commits: a Refresh or webhook enqueue for the same
  # integration meanwhile meets a conflict and is dropped. The sweep reads
  # each page by its own query and inserts outside any transaction.
  test "inserts every job outside a transaction, a full page's included" do
    for _n <- 1..51, do: insert(:calendar_integration, provider: "google", is_active: true)

    test_pid = self()
    handler = "sweep-insert-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:oban, :engine, :insert_job, :start],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:inserted, Repo.in_transaction?()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = perform_job(FallbackSyncSweepWorker, %{})

    for _n <- 1..51, do: assert_received({:inserted, false})
    refute_received {:inserted, true}
  end
end
