defmodule Tymeslot.Infrastructure.AdminAlerts.PIIScrubberTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber

  describe "scrub/1 — denylisted keys" do
    test "masks owner_email with a valid address" do
      assert PIIScrubber.scrub(%{owner_email: "alice@example.com", meeting_id: 42}) ==
               %{owner_email_masked: "a***@example.com", meeting_id: 42}
    end

    test "masks customer_email with a valid address" do
      assert PIIScrubber.scrub(%{customer_email: "bob@other.org"}) ==
               %{customer_email_masked: "b***@other.org"}
    end

    test "drops denylisted keys with invalid values without replacement" do
      assert PIIScrubber.scrub(%{owner_email: "not-an-email"}) == %{}
      assert PIIScrubber.scrub(%{owner_email: nil}) == %{}
      assert PIIScrubber.scrub(%{owner_email: 123}) == %{}
    end

    test "handles string and atom keys equivalently" do
      assert PIIScrubber.scrub(%{"owner_email" => "alice@example.com"}) ==
               %{"owner_email_masked" => "a***@example.com"}
    end
  end

  describe "scrub/1 — regex sweep over string values" do
    test "masks embedded email in a summary field" do
      input = %{summary: "User alice@example.com not found"}

      assert PIIScrubber.scrub(input) ==
               %{summary: "User a***@example.com not found"}
    end

    test "masks embedded email in a reason_message field" do
      input = %{reason_message: "Failed to reach bob@corp.co"}

      assert PIIScrubber.scrub(input) ==
               %{reason_message: "Failed to reach b***@corp.co"}
    end

    test "masks multiple embedded emails in one string" do
      input = %{note: "Sent to alice@a.com and bob@b.org"}

      assert PIIScrubber.scrub(input) ==
               %{note: "Sent to a***@a.com and b***@b.org"}
    end

    test "leaves non-email strings untouched" do
      input = %{summary: "Refund failed for order 12345"}
      assert PIIScrubber.scrub(input) == input
    end

    test "leaves non-string values untouched" do
      input = %{meeting_id: 42, retry?: true, tags: [:a, :b], count: 1.5}
      assert PIIScrubber.scrub(input) == input
    end
  end

  describe "scrub/1 — nesting and idempotence" do
    test "scrubs one level of nested maps" do
      input = %{
        context: %{owner_email: "alice@example.com", note: "x"}
      }

      assert PIIScrubber.scrub(input) ==
               %{context: %{owner_email_masked: "a***@example.com", note: "x"}}
    end

    test "leaves doubly-nested maps alone" do
      input = %{
        outer: %{inner: %{owner_email: "alice@example.com"}}
      }

      assert PIIScrubber.scrub(input) == input
    end

    test "is idempotent — scrubbing twice produces the same result" do
      input = %{
        owner_email: "alice@example.com",
        summary: "User bob@other.org failed"
      }

      once = PIIScrubber.scrub(input)
      twice = PIIScrubber.scrub(once)

      assert once == twice
    end
  end
end
