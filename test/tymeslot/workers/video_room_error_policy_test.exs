defmodule Tymeslot.Workers.VideoRoom.ErrorPolicyTest do
  use ExUnit.Case, async: false

  @moduletag :workers

  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Workers.VideoRoom.ErrorPolicy

  describe "to_result/2 with :circuit_open" do
    test "snoozes past the breaker's recovery window instead of retrying" do
      assert {:snooze, seconds} = ErrorPolicy.to_result(:circuit_open, 1)

      max_recovery_seconds = VideoCircuitBreaker.max_recovery_seconds()

      # Snoozes for at least the full recovery window, plus up to 30s of jitter.
      assert seconds > max_recovery_seconds
      assert seconds <= max_recovery_seconds + 30
    end

    test "keeps snoozing under the snooze budget" do
      assert {:snooze, _seconds} = ErrorPolicy.to_result(:circuit_open, 9)
    end

    test "discards once the snooze budget is spent, instead of snoozing forever" do
      assert {:discard, reason} = ErrorPolicy.to_result(:circuit_open, 10)
      assert reason =~ "circuit breaker"
    end
  end

  describe "to_result/3 with :circuit_open" do
    test "snoozes against the named provider's own recovery window" do
      assert {:snooze, seconds} = ErrorPolicy.to_result(:circuit_open, 1, "mirotalk")

      mirotalk_recovery_seconds =
        div(VideoCircuitBreaker.get_config(:mirotalk).recovery_timeout, 1000)

      max_recovery_seconds = VideoCircuitBreaker.max_recovery_seconds()

      assert seconds > mirotalk_recovery_seconds
      assert seconds <= mirotalk_recovery_seconds + 30
      assert seconds < max_recovery_seconds
    end

    test "accepts the provider as an atom too" do
      assert {:snooze, _seconds} = ErrorPolicy.to_result(:circuit_open, 1, :mirotalk)
    end

    test "falls back to the cross-provider window for an unrecognised provider" do
      assert {:snooze, seconds} = ErrorPolicy.to_result(:circuit_open, 1, "not_a_provider")

      max_recovery_seconds = VideoCircuitBreaker.max_recovery_seconds()
      assert seconds > max_recovery_seconds
    end

    test "still bounds the snooze budget" do
      assert {:discard, _reason} = ErrorPolicy.to_result(:circuit_open, 10, "mirotalk")
    end

    test "other reasons behave exactly like to_result/2" do
      assert ErrorPolicy.to_result(:rate_limited, 1, "zoom") ==
               ErrorPolicy.to_result(:rate_limited, 1)
    end
  end
end
