defmodule Tymeslot.Meetings.GuestsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings

  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Workers.EmailWorker

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

  describe "create_for_participant/3" do
    setup do
      %{meeting: insert(:meeting)}
    end

    test "links inserted guests to the participant", %{meeting: meeting} do
      {:ok, participant} =
        ParticipantQueries.insert(%{
          meeting_id: meeting.id,
          name: "First Booker",
          email: "first@example.com",
          timezone: "Etc/UTC",
          locale: "en"
        })

      participant_id = participant.id

      assert {:ok, [guest_a, guest_b]} =
               Guests.create_for_participant(meeting.id, participant_id, [
                 "guest-a@example.com",
                 "guest-b@example.com"
               ])

      assert guest_a.participant_id == participant_id
      assert guest_b.participant_id == participant_id
      assert guest_a.meeting_id == meeting.id
    end

    test "returns {:ok, []} for an empty list", %{meeting: meeting} do
      {:ok, participant} =
        ParticipantQueries.insert(%{
          meeting_id: meeting.id,
          name: "First Booker",
          email: "first@example.com",
          timezone: "Etc/UTC",
          locale: "en"
        })

      assert {:ok, []} = Guests.create_for_participant(meeting.id, participant.id, [])
    end
  end

  describe "invite_for_organizer/3" do
    setup do
      host = insert(:user)

      meeting =
        insert(:meeting, organizer_user_id: host.id, attendee_email: "primary@example.com")

      %{host: host, meeting: meeting}
    end

    test "adds the guests a host names and queues one invitation job for exactly them", %{
      host: host,
      meeting: meeting
    } do
      {:ok, added} = Guests.invite_for_organizer(meeting.id, host.id, ["Colleague@Example.com"])

      assert [%{id: guest_id, email: "colleague@example.com", status: "pending"}] = added
      assert [%{email: "colleague@example.com"}] = GuestQueries.list_for_meeting(meeting.id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_guest_invitations",
          "meeting_id" => meeting.id,
          "guest_ids" => [guest_id]
        }
      )
    end

    test "refuses a meeting the user does not organise, and adds nothing", %{meeting: meeting} do
      stranger = insert(:user)

      assert {:error, :not_found} =
               Guests.invite_for_organizer(meeting.id, stranger.id, ["intruder@example.com"])

      assert GuestQueries.list_for_meeting(meeting.id) == []
      refute_enqueued(worker: EmailWorker)
    end

    test "refuses a meeting id that is not a UUID", %{host: host} do
      assert {:error, :not_found} =
               Guests.invite_for_organizer("not-a-uuid", host.id, ["a@example.com"])
    end

    for {label, attrs} <- [
          {"cancelled", %{status: "cancelled"}},
          {"awaiting approval", %{status: "awaiting_approval"}},
          {"being rescheduled", %{status: "reschedule_requested"}}
        ] do
      test "refuses a meeting that is #{label}", %{host: host} do
        # A different slot from the setup's meeting, which would otherwise
        # collide with it on the one-booking-per-slot constraint.
        start_time = DateTime.add(DateTime.utc_now(:second), 3, :day)

        meeting =
          insert(
            :meeting,
            Map.merge(unquote(Macro.escape(attrs)), %{
              organizer_user_id: host.id,
              start_time: start_time,
              end_time: DateTime.add(start_time, 60, :minute)
            })
          )

        assert {:error, :closed} =
                 Guests.invite_for_organizer(meeting.id, host.id, ["late@example.com"])

        assert GuestQueries.list_for_meeting(meeting.id) == []
        refute_enqueued(worker: EmailWorker)
      end
    end

    test "refuses a meeting that has already started", %{host: host} do
      now = DateTime.utc_now(:second)

      meeting =
        insert(:meeting,
          organizer_user_id: host.id,
          start_time: DateTime.add(now, -10, :minute),
          end_time: DateTime.add(now, 50, :minute)
        )

      assert {:error, :closed} =
               Guests.invite_for_organizer(meeting.id, host.id, ["late@example.com"])
    end

    test "leaves a guest who is already invited alone, so no second invitation goes out", %{
      host: host,
      meeting: meeting
    } do
      {:ok, [first]} = Guests.create_for_meeting(meeting.id, ["colleague@example.com"])
      stamped_at = DateTime.utc_now(:second)
      {:ok, _sent} = GuestQueries.mark_confirmation_sent(first, stamped_at)

      assert {:ok, []} =
               Guests.invite_for_organizer(meeting.id, host.id, [
                 "COLLEAGUE@example.com",
                 "colleague@example.com"
               ])

      # One row still, carrying the very stamp it already had, and no job: the
      # guest was not re-queued, which is what would mail them a second time.
      assert [%{email: "colleague@example.com", confirmation_sent_at: ^stamped_at}] =
               GuestQueries.list_for_meeting(meeting.id)

      refute_enqueued(worker: EmailWorker)
    end

    test "adds only the new address when some are already there", %{
      host: host,
      meeting: meeting
    } do
      {:ok, _existing} = Guests.create_for_meeting(meeting.id, ["one@example.com"])

      {:ok, added} =
        Guests.invite_for_organizer(meeting.id, host.id, ["one@example.com", "two@example.com"])

      assert [%{email: "two@example.com"}] = added
    end

    test "drops the attendee's own address and anything unusable", %{
      host: host,
      meeting: meeting
    } do
      assert {:ok, []} =
               Guests.invite_for_organizer(meeting.id, host.id, [
                 "primary@example.com",
                 "not-an-email",
                 "  "
               ])
    end

    test "counts the cap across the guests already on the meeting", %{
      host: host,
      meeting: meeting
    } do
      full = for n <- 1..Guests.max_guests(), do: "guest#{n}@example.com"
      {:ok, _existing} = Guests.create_for_meeting(meeting.id, full)

      assert {:error, :full} =
               Guests.invite_for_organizer(meeting.id, host.id, ["late@example.com"])

      assert length(GuestQueries.list_for_meeting(meeting.id)) == Guests.max_guests()
    end

    test "fills the remaining room and stops there rather than overshooting the cap", %{
      host: host,
      meeting: meeting
    } do
      taken = for n <- 1..(Guests.max_guests() - 2), do: "guest#{n}@example.com"
      {:ok, _existing} = Guests.create_for_meeting(meeting.id, taken)

      {:ok, added} =
        Guests.invite_for_organizer(meeting.id, host.id, [
          "a@example.com",
          "b@example.com",
          "c@example.com"
        ])

      assert length(added) == 2
      assert length(GuestQueries.list_for_meeting(meeting.id)) == Guests.max_guests()
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

    for status <-
          ~w(cancelled expired completed awaiting_payment awaiting_approval reschedule_requested) do
      test "refuses a #{status} meeting and leaves the guest pending" do
        guest = guest_for(status: unquote(status))

        assert {:error, :meeting_closed} = Guests.record_rsvp(guest.rsvp_token, "accepted")
        assert {:ok, %{status: "pending"}} = GuestQueries.get_by_token(guest.rsvp_token)
      end
    end

    test "refuses a meeting whose organiser has asked to reschedule it" do
      # The time the guest would be answering for no longer holds.
      guest = guest_for(reschedule_requested_at: DateTime.utc_now(:second))

      assert {:error, :meeting_closed} = Guests.record_rsvp(guest.rsvp_token, "accepted")
      assert {:ok, %{status: "pending"}} = GuestQueries.get_by_token(guest.rsvp_token)
    end

    test "refuses a meeting that has already started" do
      guest = guest_for(started_meeting_attrs())

      assert {:error, :meeting_closed} = Guests.record_rsvp(guest.rsvp_token, "declined")
      assert {:ok, %{status: "pending"}} = GuestQueries.get_by_token(guest.rsvp_token)
    end

    test "notifies the organiser's subscribers" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
      :ok = Guests.subscribe_to_rsvp_updates(user.id)

      {:ok, _guest} = Guests.record_rsvp(guest.rsvp_token, "accepted")

      meeting_id = meeting.id
      assert_receive {:guest_rsvp_updated, ^meeting_id}
    end

    test "does not notify on a refused response" do
      user = insert(:user)
      guest = guest_for(organizer_user: user, status: "cancelled")
      :ok = Guests.subscribe_to_rsvp_updates(user.id)

      {:error, :meeting_closed} = Guests.record_rsvp(guest.rsvp_token, "accepted")

      refute_receive {:guest_rsvp_updated, _meeting_id}
    end
  end

  describe "get_open_invitation/1" do
    test "returns the guest with its meeting for an open invitation" do
      meeting = insert(:meeting)
      {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])

      assert {:ok, found} = Guests.get_open_invitation(guest.rsvp_token)
      assert found.id == guest.id
      assert found.meeting.id == meeting.id
    end

    test "rejects an unknown token" do
      assert {:error, :not_found} = Guests.get_open_invitation("nope")
    end

    test "rejects a cancelled meeting" do
      guest = guest_for(status: "cancelled")

      assert {:error, :meeting_closed} = Guests.get_open_invitation(guest.rsvp_token)
    end

    test "rejects a meeting that has already started" do
      guest = guest_for(started_meeting_attrs())

      assert {:error, :meeting_closed} = Guests.get_open_invitation(guest.rsvp_token)
    end
  end

  defp guest_for(meeting_attrs) do
    meeting = insert(:meeting, meeting_attrs)
    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
    guest
  end

  defp started_meeting_attrs do
    start_time = DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:second)
    [start_time: start_time, end_time: DateTime.add(start_time, 60, :minute)]
  end

  describe "record_rsvp/2 voids the link when the invitation is no longer live" do
    test "rejects an RSVP once the meeting has been cancelled" do
      meeting = insert(:cancelled_meeting)
      {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])

      assert {:error, :meeting_closed} = Guests.record_rsvp(guest.rsvp_token, "accepted")
    end

    test "rejects an RSVP for a guest whose owning participant has cancelled their seat" do
      meeting = insert(:meeting)

      {:ok, participant} =
        ParticipantQueries.insert(%{
          meeting_id: meeting.id,
          name: "Booker",
          email: "booker@example.com",
          timezone: "Etc/UTC",
          locale: "en"
        })

      {:ok, [guest]} =
        Guests.create_for_participant(meeting.id, participant.id, ["guest@example.com"])

      {:ok, _cancelled} = ParticipantQueries.cancel(participant)

      assert {:error, :not_found} = Guests.record_rsvp(guest.rsvp_token, "accepted")
    end

    test "accepts an RSVP for a guest whose owning participant is still live" do
      meeting = insert(:meeting)

      {:ok, participant} =
        ParticipantQueries.insert(%{
          meeting_id: meeting.id,
          name: "Booker",
          email: "booker@example.com",
          timezone: "Etc/UTC",
          locale: "en"
        })

      {:ok, [guest]} =
        Guests.create_for_participant(meeting.id, participant.id, ["guest@example.com"])

      assert {:ok, updated} = Guests.record_rsvp(guest.rsvp_token, "accepted")
      assert updated.status == "accepted"
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
