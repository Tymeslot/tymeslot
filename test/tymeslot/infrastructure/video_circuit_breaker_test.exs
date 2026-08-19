defmodule Tymeslot.Infrastructure.VideoCircuitBreakerTest do
  use Tymeslot.DataCase, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.VideoCircuitBreaker

  import ExUnit.CaptureLog

  setup do
    # These breakers are global named processes shared across the whole test
    # run. Reset before each test for a clean slate, and on_exit so the last
    # test in this module doesn't leave a breaker open for other modules
    # (e.g. CircuitBreakerSupervisorTest, which asserts they start closed).
    reset_breakers = fn ->
      VideoCircuitBreaker.reset(:google_meet)
      VideoCircuitBreaker.reset(:teams)
      VideoCircuitBreaker.reset(:mirotalk)
    end

    reset_breakers.()
    on_exit(reset_breakers)
    :ok
  end

  describe "call/2" do
    test "executes function successfully for valid provider" do
      result =
        VideoCircuitBreaker.call(:google_meet, fn ->
          {:ok, "success"}
        end)

      assert {:ok, "success"} = result
    end

    test "returns error for invalid provider" do
      result =
        VideoCircuitBreaker.call(:invalid_provider, fn ->
          {:ok, "should not execute"}
        end)

      assert {:error, {:invalid_provider, :invalid_provider}} = result
    end

    test "returns error when function is not arity 0" do
      result =
        VideoCircuitBreaker.call(:google_meet, fn _arg ->
          {:ok, "should not match"}
        end)

      assert {:error, {:invalid_provider, :google_meet}} = result
    end

    test "propagates circuit open error" do
      # Trigger circuit breaker to open by causing failures
      # The google_meet config has failure_threshold: 5
      for _i <- 1..5 do
        VideoCircuitBreaker.call(:google_meet, fn ->
          {:provider_error, :simulated_failure}
        end)
      end

      # Next call should return circuit open
      log =
        capture_log(fn ->
          result =
            VideoCircuitBreaker.call(:google_meet, fn ->
              {:ok, "should not execute"}
            end)

          assert {:error, :circuit_open} = result
        end)

      assert log =~ "Circuit breaker open"
    end

    test "propagates operation failure" do
      log =
        capture_log(fn ->
          result =
            VideoCircuitBreaker.call(:teams, fn ->
              {:error, :api_timeout}
            end)

          assert {:error, :api_timeout} = result
        end)

      assert log =~ "Operation failed"
    end

    test "catches exceptions and returns error" do
      log =
        capture_log(fn ->
          result =
            VideoCircuitBreaker.call(:mirotalk, fn ->
              raise "unexpected error"
            end)

          # CircuitBreaker wraps the exception in an error tuple
          assert {:error, _reason} = result
        end)

      assert log =~ "Circuit breaker caught exception"
    end

    test "works for all valid video providers" do
      providers = [:mirotalk, :google_meet, :teams]

      for provider <- providers do
        result =
          VideoCircuitBreaker.call(provider, fn ->
            {:ok, provider}
          end)

        assert {:ok, ^provider} = result
      end
    end
  end

  describe "status/1" do
    test "returns status map for valid provider" do
      status = VideoCircuitBreaker.status(:google_meet)

      assert %{status: state} = status
      assert state in [:closed, :open, :half_open]
    end

    test "returns error for invalid provider" do
      result = VideoCircuitBreaker.status(:invalid)

      assert {:error, {:invalid_provider, :invalid}} = result
    end

    test "reflects circuit state after failures" do
      # Reset to ensure clean state
      VideoCircuitBreaker.reset(:teams)

      # Should start closed
      status = VideoCircuitBreaker.status(:teams)
      assert status.status == :closed

      # Cause failures to open circuit (teams has threshold of 5)
      for _i <- 1..5 do
        VideoCircuitBreaker.call(:teams, fn ->
          {:provider_error, :simulated_failure}
        end)
      end

      # Should now be open
      status = VideoCircuitBreaker.status(:teams)
      assert status.status == :open

      # Reset for other tests
      VideoCircuitBreaker.reset(:teams)
    end
  end

  describe "reset/1" do
    test "resets circuit breaker to closed state" do
      # Open the circuit first
      for _i <- 1..5 do
        VideoCircuitBreaker.call(:mirotalk, fn ->
          {:provider_error, :failure}
        end)
      end

      # Verify it's open
      status = VideoCircuitBreaker.status(:mirotalk)
      assert status.status == :open

      # Reset it - logs at info level
      assert :ok = VideoCircuitBreaker.reset(:mirotalk)

      # Verify it's closed
      status = VideoCircuitBreaker.status(:mirotalk)
      assert status.status == :closed
    end

    test "returns error for invalid provider" do
      result = VideoCircuitBreaker.reset(:invalid)

      assert {:error, {:invalid_provider, :invalid}} = result
    end
  end

  describe "get_config/1" do
    test "returns configuration for google_meet with custom values" do
      config = VideoCircuitBreaker.get_config(:google_meet)

      assert config.failure_threshold == 5
      assert config.time_window == :timer.minutes(1)
      assert config.recovery_timeout == :timer.minutes(5)
      assert config.half_open_requests == 2
    end

    test "returns configuration for teams with custom values" do
      config = VideoCircuitBreaker.get_config(:teams)

      assert config.failure_threshold == 5
      assert config.time_window == :timer.minutes(1)
      assert config.recovery_timeout == :timer.minutes(5)
      assert config.half_open_requests == 2
    end

    test "returns configuration for mirotalk" do
      config = VideoCircuitBreaker.get_config(:mirotalk)

      assert config.failure_threshold == 3
      assert config.time_window == :timer.minutes(1)
      assert config.recovery_timeout == :timer.minutes(2)
      assert config.half_open_requests == 2
    end

    test "returns default config for unknown provider" do
      config = VideoCircuitBreaker.get_config(:unknown_provider)

      # Should return defaults
      assert config.failure_threshold == 3
      assert config.time_window == :timer.minutes(1)
      assert config.recovery_timeout == :timer.minutes(2)
      assert config.half_open_requests == 2
    end
  end

  describe "configuration consistency" do
    test "supervisor and wrapper use same configuration" do
      # This test verifies that the supervisor gets config from the wrapper
      # by checking that get_config returns expected values
      expected = %{
        mirotalk: %{
          failure_threshold: 3,
          time_window: :timer.minutes(1),
          recovery_timeout: :timer.minutes(2),
          half_open_requests: 2
        },
        google_meet: %{
          failure_threshold: 5,
          time_window: :timer.minutes(1),
          recovery_timeout: :timer.minutes(5),
          half_open_requests: 2
        },
        teams: %{
          failure_threshold: 5,
          time_window: :timer.minutes(1),
          recovery_timeout: :timer.minutes(5),
          half_open_requests: 2
        }
      }

      for {provider, expected_config} <- expected do
        assert VideoCircuitBreaker.get_config(provider) == expected_config,
               "unexpected circuit breaker configuration for #{provider}"
      end
    end
  end

  describe "max_recovery_seconds/0" do
    test "returns the longest recovery_timeout across every provider, in seconds" do
      longest_ms =
        [:google_meet, :teams, :mirotalk, :zoom]
        |> Enum.map(&VideoCircuitBreaker.get_config/1)
        |> Enum.map(& &1.recovery_timeout)
        |> Enum.max()

      assert VideoCircuitBreaker.max_recovery_seconds() == div(longest_ms, 1_000)
    end
  end
end
