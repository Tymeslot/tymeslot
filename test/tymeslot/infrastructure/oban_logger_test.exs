defmodule Tymeslot.Infrastructure.ObanLoggerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CorrelationId
  alias Tymeslot.Infrastructure.ObanLogger

  # Runs job:start in a fresh process, as Oban does, and returns the user_id
  # it left in Logger metadata and in the ErrorTracker context.
  defp start_context(job) do
    Task.await(
      Task.async(fn ->
        ObanLogger.handle_event([:oban, :job, :start], %{system_time: 0}, %{job: job}, [])
        {Logger.metadata()[:user_id], ErrorTracker.get_context()["user_id"]}
      end)
    )
  end

  defp job do
    %Oban.Job{
      id: 123,
      args: %{"foo" => "bar"},
      queue: "default",
      worker: "MyApp.SomeWorker",
      attempt: 1,
      max_attempts: 3,
      meta: %{},
      tags: []
    }
  end

  describe "handle_event/4 - correlation_id on job:start" do
    test "sets correlation_id in process dict and Logger metadata" do
      result =
        Task.await(
          Task.async(fn ->
            ObanLogger.handle_event(
              [:oban, :job, :start],
              %{system_time: 0},
              %{job: job()},
              []
            )

            {CorrelationId.get_from_process(), Logger.metadata()[:correlation_id]}
          end)
        )

      {process_id, logger_id} = result

      assert {:ok, _uuid_info} = UUID.info(process_id)
      assert process_id == logger_id
    end

    test "generates a unique correlation_id per invocation" do
      ids =
        for _i <- 1..10 do
          Task.await(
            Task.async(fn ->
              ObanLogger.handle_event([:oban, :job, :start], %{system_time: 0}, %{job: job()}, [])
              CorrelationId.get_from_process()
            end)
          )
        end

      assert length(Enum.uniq(ids)) == 10
    end
  end

  describe "handle_event/4 - user_id on job:start" do
    test "tags the job with the user its args name, as Logger metadata and error context" do
      for {key, user_id} <- [{"user_id", 41}, {"organizer_user_id", 42}] do
        job = %{job() | args: %{key => user_id}}

        assert start_context(job) == {user_id, user_id}
      end
    end

    test "sets no user_id for a job whose args name no user" do
      assert start_context(job()) == {nil, nil}
    end

    test "falls back to the user its enqueuer named in meta" do
      assert start_context(%{job() | meta: %{"user_id" => 7}}) == {7, 7}
    end

    test "prefers the user its args name over the one in meta" do
      job = %{job() | args: %{"user_id" => 9}, meta: %{"user_id" => 7}}

      assert start_context(job) == {9, 9}
    end
  end

  describe "handle_event/4 - correlation_id inherited from the enqueuer" do
    defp start_correlation_id(job) do
      Task.await(
        Task.async(fn ->
          ObanLogger.handle_event([:oban, :job, :start], %{system_time: 0}, %{job: job}, [])

          {CorrelationId.get_from_process(), Logger.metadata()[:correlation_id],
           ErrorTracker.get_context()["correlation_id"]}
        end)
      )
    end

    test "restores the correlation id the job's meta carries" do
      job = %{job() | meta: %{"correlation_id" => "abc12345"}}

      assert start_correlation_id(job) == {"abc12345", "abc12345", "abc12345"}
    end

    test "replaces an invalid correlation id in meta with a fresh one" do
      job = %{job() | meta: %{"correlation_id" => "bad id\n"}}

      {correlation_id, correlation_id, correlation_id} = start_correlation_id(job)

      assert correlation_id != "bad id\n"
      assert CorrelationId.valid?(correlation_id)
    end
  end

  describe "handle_event/4 - job:exception level" do
    test "logs a retryable failure at :warning, not :error" do
      meta = %{job: job(), state: :failure, kind: :error, reason: %RuntimeError{message: "boom"}}

      at_error =
        capture_log([level: :error], fn ->
          ObanLogger.handle_event([:oban, :job, :exception], measurements(), meta, [])
        end)

      at_warning =
        capture_log([level: :warning], fn ->
          ObanLogger.handle_event([:oban, :job, :exception], measurements(), meta, [])
        end)

      # Assert ObanLogger did not emit its own message at :error level. We can't
      # assert the whole capture is empty: capture_log is VM-global, so under
      # concurrent async tests it also picks up unrelated error logs from other
      # tests (e.g. circuit breakers tripping).
      refute at_error =~ "job:exception"
      assert at_warning =~ "job:exception"
    end

    test "logs a terminal failure at :error" do
      meta = %{job: job(), state: :discard, kind: :error, reason: %RuntimeError{message: "boom"}}

      at_error =
        capture_log([level: :error], fn ->
          ObanLogger.handle_event([:oban, :job, :exception], measurements(), meta, [])
        end)

      assert at_error =~ "job:exception"
    end
  end

  describe "handle_event/4 - sensitive args" do
    setup do
      # The test env logger level is :warning, which would drop the :info
      # start/stop lines before capture_log sees them.
      :ok = Logger.put_module_level(ObanLogger, :info)
      on_exit(fn -> Logger.delete_module_level(ObanLogger) end)
    end

    test "never includes job args in log output" do
      secret_job = %{
        job()
        | args: %{"reset_url" => "https://example.com/reset-password/secret-token-123"}
      }

      for {event, meta} <- [
            {:start, %{job: secret_job}},
            {:stop, %{job: secret_job, state: :success}},
            {:exception,
             %{
               job: secret_job,
               state: :discard,
               kind: :error,
               reason: %RuntimeError{message: "boom"}
             }}
          ] do
        output =
          capture_log([level: :info], fn ->
            ObanLogger.handle_event(
              [:oban, :job, event],
              %{system_time: 0, duration: 1000, queue_time: 500},
              meta,
              []
            )
          end)

        assert output =~ "job:#{event}"
        refute output =~ "secret-token-123"
        refute output =~ "reset_url"
      end
    end
  end

  describe "handle_event/4 - resilience" do
    test "never raises even on malformed telemetry payloads" do
      capture_log(fn ->
        assert :ok = ObanLogger.handle_event([:oban, :job, :start], %{}, %{}, [])
        assert :ok = ObanLogger.handle_event([:oban, :job, :stop], %{}, %{}, [])
        assert :ok = ObanLogger.handle_event([:oban, :job, :exception], %{}, %{}, [])
      end)
    end
  end

  defp measurements, do: %{duration: 1000, queue_time: 500}
end
