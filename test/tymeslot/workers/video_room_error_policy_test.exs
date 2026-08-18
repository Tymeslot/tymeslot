defmodule Tymeslot.Workers.VideoRoom.ErrorPolicyTest do
  use ExUnit.Case, async: true

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

    test "does not vary with attempt number" do
      assert {:snooze, _seconds} = ErrorPolicy.to_result(:circuit_open, 9)
    end
  end
end
