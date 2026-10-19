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
      assert PIIScrubber.scrub(%{owner_email: "Contact alice@example.com"}) == %{}
    end

    test "masks other denylisted email keys" do
      assert PIIScrubber.scrub(%{email: "alice@example.com"}) == %{
               email_masked: "a***@example.com"
             }

      assert PIIScrubber.scrub(%{user_email: "bob@other.org"}) == %{
               user_email_masked: "b***@other.org"
             }

      assert PIIScrubber.scrub(%{recipient_email: "carol@test.com"}) == %{
               recipient_email_masked: "c***@test.com"
             }
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

    # An address nested in a context map reaches the admin's inbox like any
    # other: it is masked at every depth, by key and by sweep.
    test "masks addresses in doubly-nested maps" do
      input = %{
        outer: %{inner: %{owner_email: "alice@example.com", note: "cc bob@other.org"}}
      }

      assert %{outer: %{inner: inner}} = PIIScrubber.scrub(input)
      assert inner == %{owner_email_masked: "a***@example.com", note: "cc b***@other.org"}
    end

    # The key rule is the log redactor's: any `*_email` or `*_recipient` key,
    # not a fixed list.
    test "masks an email key outside the alerts' usual names" do
      assert PIIScrubber.scrub(%{context: %{"attendee_email" => "carol@example.com"}}) ==
               %{context: %{"attendee_email_masked" => "c***@example.com"}}

      assert PIIScrubber.scrub(%{admin_recipient: "dave@example.com"}) ==
               %{"admin_recipient_masked" => "d***@example.com"}
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
