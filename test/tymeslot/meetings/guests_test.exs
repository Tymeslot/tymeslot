defmodule Tymeslot.Meetings.GuestsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings

  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests

  describe "sanitize_emails/2" do
    test "trims, downcases and de-duplicates" do
      assert Guests.sanitize_emails(
               ["  Alice@Example.com ", "alice@example.com", "bob@example.com"],
               "host@example.com"
             ) == ["alice@example.com", "bob@example.com"]
    end

    test "drops blanks and invalid addresses" do
      assert Guests.sanitize_emails(
               ["", "  ", "not-an-email", "ok@example.com"],
               "host@example.com"
             ) ==
               ["ok@example.com"]
    end

    test "excludes the primary attendee's own email (case-insensitively)" do
      assert Guests.sanitize_emails(
               ["Primary@Example.com", "guest@example.com"],
               "primary@example.com"
             ) ==
               ["guest@example.com"]
    end

    test "caps the list at max_guests" do
      emails = for n <- 1..(Guests.max_guests() + 5), do: "guest#{n}@example.com"
      result = Guests.sanitize_emails(emails, "host@example.com")

      assert length(result) == Guests.max_guests()
    end

    test "tolerates non-list input" do
      assert Guests.sanitize_emails(nil, "host@example.com") == []
    end
  end

  describe "create_for_meeting/2" do
    test "inserts a guest row per email with a pending status and a token" do
      meeting = insert(:meeting)

      {:ok, guests} = Guests.create_for_meeting(meeting.id, ["a@example.com", "b@example.com"])

      assert length(guests) == 2
      assert Enum.all?(guests, &(&1.status == "pending"))
      assert Enum.all?(guests, &(byte_size(&1.rsvp_token) > 0))

      stored = GuestQueries.list_for_meeting(meeting.id)
      assert Enum.map(stored, & &1.email) == ["a@example.com", "b@example.com"]
    end

    test "is a no-op for an empty list" do
      meeting = insert(:meeting)
      assert {:ok, []} = Guests.create_for_meeting(meeting.id, [])
    end
  end

  describe "record_rsvp/2" do
    setup do
      meeting = insert(:meeting)
      {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
      %{guest: guest}
    end

    test "accepts via token and stamps responded_at", %{guest: guest} do
      assert {:ok, updated} = Guests.record_rsvp(guest.rsvp_token, "accepted")
      assert updated.status == "accepted"
      assert updated.responded_at != nil
    end

    test "declines via token", %{guest: guest} do
      assert {:ok, updated} = Guests.record_rsvp(guest.rsvp_token, "declined")
      assert updated.status == "declined"
    end

    test "rejects an unknown token" do
      assert {:error, :not_found} = Guests.record_rsvp("nope", "accepted")
    end

    test "rejects an invalid response", %{guest: guest} do
      assert {:error, :invalid_response} = Guests.record_rsvp(guest.rsvp_token, "maybe")
    end
  end

  describe "summarize/1" do
    test "aggregates RSVP counts" do
      meeting = insert(:meeting)
      {:ok, [g1, g2, _g3]} = Guests.create_for_meeting(meeting.id, ~w(a@x.com b@x.com c@x.com))
      {:ok, _accepted} = Guests.record_rsvp(g1.rsvp_token, "accepted")
      {:ok, _declined} = Guests.record_rsvp(g2.rsvp_token, "declined")

      summary = Guests.summarize(GuestQueries.list_for_meeting(meeting.id))

      assert summary == %{total: 3, accepted: 1, declined: 1, pending: 1}
    end
  end
end
