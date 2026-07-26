defmodule Tymeslot.Infrastructure.ObanLoggerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CorrelationId
  alias Tymeslot.Infrastructure.ObanLogger

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
