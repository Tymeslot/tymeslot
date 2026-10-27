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
    # A failed probe is logged as a warning once, by `HealthCheck.ErrorAnalysis`,
    # with the integration it concerns; this handler only adds a debug line.
    test "a failed health check logs at :debug level" do
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log([level: :debug], fn ->
          Telemetry.handle_event(
            [:tymeslot, :integration, :health_check],
            %{duration: 50},
            %{provider: :test, success: false},
            nil
          )
        end)

      assert log =~ "[debug] Health check: test - failed (50ms)"
      refute log =~ "[warning]"
    end

    test "a passed health check logs at :debug level" do
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

      assert log =~ "[debug] Health check: test - passed (50ms)"
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
