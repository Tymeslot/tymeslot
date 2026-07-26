defmodule Tymeslot.Integrations.TelemetryTest do
  use ExUnit.Case, async: false

  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Telemetry

  setup do
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"
    %{handler_id: handler_id}
  end

  describe "events/0" do
    test "returns the full list of event name lists" do
      events = Telemetry.events()

      refute Enum.empty?(events)

      # Verify some expected events are present
      assert [:tymeslot, :integration, :operation, :start] in events
      assert [:tymeslot, :integration, :operation, :stop] in events
      assert [:tymeslot, :integration, :operation, :exception] in events
      assert [:tymeslot, :integration, :api_call, :start] in events
      assert [:tymeslot, :integration, :health_check] in events
      assert [:tymeslot, :cache, :hit] in events
      assert [:tymeslot, :cache, :miss] in events
      assert [:tymeslot, :integration, :sync, :start] in events
    end
  end

  describe "attach_default_handlers/0" do
    setup do
      try do
        :telemetry.detach("tymeslot-integration-logger")
      rescue
        _error -> :ok
      end

      on_exit(fn ->
        try do
          :telemetry.detach("tymeslot-integration-logger")
        rescue
          _error -> :ok
        end
      end)

      :ok
    end

    test "attaches handler named 'tymeslot-integration-logger'" do
      assert :ok = Telemetry.attach_default_handlers()
    end

    test "returns {:error, :already_exists} on second call" do
      assert :ok = Telemetry.attach_default_handlers()
      assert {:error, :already_exists} = Telemetry.attach_default_handlers()
    end
  end

  describe "span/3" do
    test "emits start and stop events on success", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:test, :op, :start],
          [:test, :op, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      result = Telemetry.span([:test, :op], %{operation: :test_op}, fn -> :span_result end)

      assert result == :span_result

      assert_receive {:telemetry, ^ref, [:test, :op, :start], %{system_time: _time},
                      %{operation: :test_op, correlation_id: _cid}}

      assert_receive {:telemetry, ^ref, [:test, :op, :stop], %{duration: duration},
                      %{result: :ok}}

      assert is_integer(duration)
      assert duration >= 0
    end

    test "emits start and exception events on failure, reraises", %{handler_id: handler_id} do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:test, :fail, :start],
          [:test, :fail, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, ref, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert_raise RuntimeError, "span error", fn ->
        Telemetry.span([:test, :fail], %{operation: :failing}, fn ->
          raise "span error"
        end)
      end

      assert_receive {:telemetry, ^ref, [:test, :fail, :start], _measurements, _metadata}

      assert_receive {:telemetry, ^ref, [:test, :fail, :exception], %{duration: _duration},
                      %{kind: :error, reason: reason}}

      assert reason =~ "span error"
    end
  end

  describe "handle_event/4 log levels" do
    test "exception events use :error level" do
      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:tymeslot, :integration, :operation, :exception],
            %{duration: 100},
            %{operation: :test, reason: "boom", kind: :error, stacktrace: []},
            nil
          )
        end)

      assert log =~ "[error] Integration operation failed: test - boom"
    end

    test "unhealthy health check uses :warning level" do
      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:tymeslot, :integration, :health_check],
            %{duration: 50},
            %{provider: :test, success: false},
            nil
          )
        end)

      assert log =~ "[warning] Health check: test - unhealthy (50ms)"
    end

    test "circuit breaker open uses :error level" do
      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:tymeslot, :integration, :circuit_breaker, :state_change],
            %{},
            %{to: :open, from: :closed, provider: :test},
            nil
          )
        end)

      assert log =~ "[error] Event: tymeslot.integration.circuit_breaker.state_change"
    end

    test "default events use :debug level" do
      # The suite runs at :warning and the primary level filters messages before
      # they reach capture_log's handler, so it has to be lowered here. Safe
      # because this module is async: false and runs in ExUnit's sync phase.
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:tymeslot, :cache, :hit],
            %{},
            %{cache: :test_cache},
            nil
          )
        end)

      assert log =~ "[debug] Cache hit: test_cache"
    end
  end
end
