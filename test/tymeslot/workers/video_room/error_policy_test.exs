defmodule Tymeslot.Workers.VideoRoom.ErrorPolicyTest do
  @moduledoc """
  The classification layer between a video provider's failure and Oban's verdict.

  The distinction this module exists to draw is whether a failure will pass on
  its own. Getting it wrong in the retryable direction is expensive and was the
  cause of a daily admin alert: a Teams account with no licence reported its
  refusal as a sentence, nothing recognised it, and the job spent all ten
  attempts before alerting — every day, as the recovery scan re-queued it.

  The `:circuit_open` cases below read `VideoCircuitBreaker`'s configured
  recovery windows, which are global, so this module cannot run async.
  """

  use ExUnit.Case, async: false

  @moduletag :workers

  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Workers.VideoRoom.ErrorPolicy

  describe "categorize/1" do
    test "recognises an account that cannot host video meetings" do
      assert {:error, :video_meeting_not_enabled} =
               ErrorPolicy.categorize(:video_meeting_not_enabled)
    end

    test "passes an unrecognised reason through for an ordinary retry" do
      assert {:error, :some_new_provider_hiccup} =
               ErrorPolicy.categorize(:some_new_provider_hiccup)
    end
  end

  describe "terminal?/1" do
    test "treats an account that cannot host video meetings as terminal" do
      assert ErrorPolicy.terminal?(:video_meeting_not_enabled)
    end

    test "does not treat a rate limit or an outage as terminal" do
      refute ErrorPolicy.terminal?(:rate_limited)
      refute ErrorPolicy.terminal?(:service_unavailable)
    end

    test "does not treat a free-text reason as terminal" do
      # Why providers must return tagged reasons: a sentence can never be
      # classified, so it is retried to exhaustion whatever it says.
      refute ErrorPolicy.terminal?("Teams meeting link was not generated for this event.")
    end
  end

  describe "to_result/2" do
    test "discards an account that cannot host video meetings instead of retrying" do
      assert {:discard, "Account cannot host video meetings"} =
               ErrorPolicy.to_result(:video_meeting_not_enabled, 1)
    end

    test "keeps snoozing a rate limit" do
      assert {:snooze, seconds} = ErrorPolicy.to_result(:rate_limited, 1)
      assert seconds > 0
    end
  end

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
