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

  describe "add_to_meeting/3" do
    test "adds the guests a host names after the booking was made" do
      meeting = insert(:meeting, attendee_email: "primary@example.com")

      {:ok, added} =
        Guests.add_to_meeting(meeting.id, ["Colleague@Example.com"], meeting.attendee_email)

      assert [%{email: "colleague@example.com", status: "pending"}] = added
      assert [%{email: "colleague@example.com"}] = GuestQueries.list_for_meeting(meeting.id)
    end

    test "leaves a guest who is already invited alone, so no second invitation goes out" do
      meeting = insert(:meeting, attendee_email: "primary@example.com")
      {:ok, [first]} = Guests.create_for_meeting(meeting.id, ["colleague@example.com"])
      stamped_at = DateTime.utc_now(:second)
      {:ok, _sent} = GuestQueries.mark_confirmation_sent(first, stamped_at)

      assert {:ok, []} =
               Guests.add_to_meeting(
                 meeting.id,
                 ["COLLEAGUE@example.com", "colleague@example.com"],
                 meeting.attendee_email
               )

      # One row still, carrying the very stamp it already had: the guest was not
      # re-queued, which is what would mail them a second invitation.
      assert [%{email: "colleague@example.com", confirmation_sent_at: ^stamped_at}] =
               GuestQueries.list_for_meeting(meeting.id)
    end

    test "adds only the new address when some are already there" do
      meeting = insert(:meeting, attendee_email: "primary@example.com")
      {:ok, _existing} = Guests.create_for_meeting(meeting.id, ["one@example.com"])

      {:ok, added} =
        Guests.add_to_meeting(
          meeting.id,
          ["one@example.com", "two@example.com"],
          meeting.attendee_email
        )

      assert [%{email: "two@example.com"}] = added
    end

    test "drops the attendee's own address and anything unusable" do
      meeting = insert(:meeting, attendee_email: "primary@example.com")

      assert {:ok, []} =
               Guests.add_to_meeting(
                 meeting.id,
                 ["primary@example.com", "not-an-email", "  "],
                 meeting.attendee_email
               )
    end

    test "counts the cap across the guests already on the meeting" do
      meeting = insert(:meeting, attendee_email: "primary@example.com")
      full = for n <- 1..Guests.max_guests(), do: "guest#{n}@example.com"
      {:ok, _existing} = Guests.create_for_meeting(meeting.id, full)

      assert {:error, :full} =
               Guests.add_to_meeting(meeting.id, ["late@example.com"], meeting.attendee_email)

      assert length(GuestQueries.list_for_meeting(meeting.id)) == Guests.max_guests()
    end

    test "fills the remaining room and stops there rather than overshooting the cap" do
      meeting = insert(:meeting, attendee_email: "primary@example.com")
      taken = for n <- 1..(Guests.max_guests() - 2), do: "guest#{n}@example.com"
      {:ok, _existing} = Guests.create_for_meeting(meeting.id, taken)

      {:ok, added} =
        Guests.add_to_meeting(
          meeting.id,
          ["a@example.com", "b@example.com", "c@example.com"],
          meeting.attendee_email
        )

      assert length(added) == 2
      assert length(GuestQueries.list_for_meeting(meeting.id)) == Guests.max_guests()
    end
  end

  describe "remaining_capacity/1" do
    test "counts down from the cap as guests are added" do
      meeting = insert(:meeting)
      assert Guests.remaining_capacity(meeting.id) == Guests.max_guests()

      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["one@example.com"])
      assert Guests.remaining_capacity(meeting.id) == Guests.max_guests() - 1
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
      assert %DateTime{} = updated.responded_at
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
