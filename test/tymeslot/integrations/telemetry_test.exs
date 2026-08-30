defmodule Tymeslot.Integrations.TelemetryTest do
  use ExUnit.Case, async: false

  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Telemetry

  describe "events/0" do
    test "returns the health-check event, the only event this system emits" do
      assert Telemetry.events() == [[:tymeslot, :integration, :health_check]]
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

  describe "handle_event/4 log levels" do
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

    test "healthy health check uses :debug level" do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:tymeslot, :integration, :health_check],
            %{duration: 50},
            %{provider: :test, success: true},
            nil
          )
        end)

      assert log =~ "[debug] Health check: test - healthy (50ms)"
    end

    test "an unrecognised event falls back to the generic message at :debug level" do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:tymeslot, :integration, :test_connection],
            %{},
            %{},
            nil
          )
        end)

      assert log =~ "[debug] Event: tymeslot.integration.test_connection"
    end
  end
end
