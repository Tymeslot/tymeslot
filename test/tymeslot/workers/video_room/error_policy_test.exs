defmodule Tymeslot.Workers.VideoRoom.ErrorPolicyTest do
  @moduledoc """
  The classification layer between a video provider's failure and Oban's verdict.

  The distinction this module exists to draw is whether a failure will pass on
  its own. Getting it wrong in the retryable direction is expensive and was the
  cause of a daily admin alert: a Teams account with no licence reported its
  refusal as a sentence, nothing recognised it, and the job spent all ten
  attempts before alerting — every day, as the recovery scan re-queued it.
  """

  use ExUnit.Case, async: true

  @moduletag :workers

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
end
