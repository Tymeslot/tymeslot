defmodule Tymeslot.Infrastructure.ObanEngineTest do
  use Tymeslot.DataCase, async: true

  @moduletag :infrastructure
  @moduletag :workers

  alias Tymeslot.Infrastructure.CorrelationId
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ObanEngine

  @queue :oban_engine_test

  # Reports the context the job ran with, so what a job inherited is read off
  # the mailbox. Draining runs it in the test process.
  defmodule ContextWorker do
    use Oban.Worker, queue: :oban_engine_test

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      send(
        self(),
        {:ran_with, Logger.metadata()[:correlation_id], Logger.metadata()[:user_id],
         ErrorTracking.current_context()["correlation_id"]}
      )

      :ok
    end
  end

  # Enqueues with the given context in the calling process, then clears it,
  # so the drained job can only have its context from what was inserted.
  defp insert_with_context(context, args \\ %{}, opts \\ []) do
    Logger.metadata(context)
    {:ok, job} = Oban.insert(ContextWorker.new(args, opts))
    Logger.reset_metadata()
    job
  end

  defp drain do
    assert %{success: 1} = Oban.drain_queue(queue: @queue)
  end

  test "is the engine the application's Oban runs" do
    assert Oban.config().engine == ObanEngine
  end

  describe "a job enqueued with a correlation id in context" do
    test "runs with the enqueuer's correlation id and user" do
      job = insert_with_context(correlation_id: "abc12345", user_id: 7)

      assert job.meta == %{"correlation_id" => "abc12345", "user_id" => 7}

      drain()
      assert_received {:ran_with, "abc12345", 7, "abc12345"}
    end

    test "does not carry the enqueuer's user when the args name one" do
      job = insert_with_context([correlation_id: "abc12345", user_id: 7], %{user_id: 9})

      assert job.meta == %{"correlation_id" => "abc12345"}

      drain()
      assert_received {:ran_with, "abc12345", 9, "abc12345"}
    end

    test "keeps a meta key the caller set" do
      job =
        insert_with_context(
          [correlation_id: "abc12345", user_id: 7],
          %{},
          meta: %{"correlation_id" => "explicit-id", "source" => "test"}
        )

      assert job.meta == %{"correlation_id" => "explicit-id", "source" => "test", "user_id" => 7}
    end

    test "carries it through insert_all" do
      Logger.metadata(correlation_id: "abc12345")
      [job] = Oban.insert_all([ContextWorker.new(%{})])
      Logger.reset_metadata()

      assert job.meta == %{"correlation_id" => "abc12345"}
    end
  end

  describe "a job enqueued without a usable correlation id" do
    test "carries nothing and runs with a fresh id" do
      job = insert_with_context(user_id: 7)

      assert job.meta == %{}

      drain()
      assert_received {:ran_with, correlation_id, nil, correlation_id}
      assert CorrelationId.valid?(correlation_id)
    end

    test "ignores an invalid id in context" do
      job = insert_with_context(correlation_id: "bad id\n")

      assert job.meta == %{}
    end
  end
end
