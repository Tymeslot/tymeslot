defmodule Tymeslot.Workers.RetryHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :workers
  @moduletag :unit

  alias Tymeslot.Workers.RetryHelpers

  describe "clamp_retry_after/2" do
    test "keeps a value inside the bounds" do
      assert RetryHelpers.clamp_retry_after(45, min: 10, max: 600, default: 30) == 45
    end

    test "raises a value below the floor and lowers one above the ceiling" do
      assert RetryHelpers.clamp_retry_after(2, min: 10, max: 600, default: 30) == 10
      assert RetryHelpers.clamp_retry_after(900, min: 10, max: 600, default: 30) == 600
    end

    test "returns the default for a missing or non-integer value" do
      assert RetryHelpers.clamp_retry_after(nil, max: 600, default: 30) == 30
      assert RetryHelpers.clamp_retry_after("45", max: 600, default: 30) == 30
    end
  end

  describe "parse_retry_after_from_last_error/1" do
    test "reads the value from the most recent error only" do
      job = %Oban.Job{
        errors: [
          %{"attempt" => 1, "error" => "rate limited, retry_after:90"},
          %{"attempt" => 2, "error" => "rate limited, retry_after:45"}
        ]
      }

      assert RetryHelpers.parse_retry_after_from_last_error(job) == 45
    end

    test "returns nil when the job has no errors" do
      assert RetryHelpers.parse_retry_after_from_last_error(%Oban.Job{errors: []}) == nil
    end
  end
end
