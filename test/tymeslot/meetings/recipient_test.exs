defmodule Tymeslot.Meetings.RecipientTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings

  import Tymeslot.Factory

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.ParticipantQueries

  defp insert_group_meeting(_context) do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 5)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        attendee_name: nil,
        attendee_email: nil,
        attendee_phone: nil,
        attendee_company: nil,
        attendee_message: nil,
        attendee_timezone: nil
      )

    %{user: user, meeting_type: meeting_type, meeting: meeting}
  end

  defp insert_participant(meeting, attrs) do
    {:ok, participant} =
      ParticipantQueries.insert(
        Map.merge(
          %{
            meeting_id: meeting.id,
            name: "Pat Participant",
            email: "pat@example.com",
            timezone: "Europe/Berlin",
            locale: "de"
          },
          attrs
        )
      )

    participant
  end

  describe "recipients/1" do
    test "solo meeting returns one attendee recipient built from attendee_* fields" do
      meeting =
        insert(:meeting,
          attendee_name: "Solo Attendee",
          attendee_email: "solo@example.com",
          attendee_timezone: "America/New_York",
          attendee_locale: "en"
        )

      assert [recipient] = Meetings.recipients(meeting)
      assert recipient.kind == :attendee
      assert recipient.name == "Solo Attendee"
      assert recipient.email == "solo@example.com"
      assert recipient.timezone == "America/New_York"
      assert recipient.locale == "en"
      assert recipient.participant_id == nil
    end

    setup :insert_group_meeting

    test "group meeting returns one recipient per live participant", %{meeting: meeting} do
      p1 = insert_participant(meeting, %{email: "one@example.com"})
      _p2 = insert_participant(meeting, %{email: "two@example.com", locale: "fr"})

      cancelled = insert_participant(meeting, %{email: "gone@example.com"})
      {:ok, _cancelled} = ParticipantQueries.cancel(cancelled)

      recipients = Meetings.recipients(meeting)

      assert length(recipients) == 2
      assert Enum.all?(recipients, &(&1.kind == :participant))

      assert Enum.map(recipients, & &1.email) |> Enum.sort() == [
               "one@example.com",
               "two@example.com"
             ]

      assert Enum.find(recipients, &(&1.email == "one@example.com")).participant_id == p1.id
      refute Enum.any?(recipients, &(&1.email == "gone@example.com"))
    end

    test "group meeting with no live participants returns []", %{meeting: meeting} do
      cancelled = insert_participant(meeting, %{})
      {:ok, _cancelled} = ParticipantQueries.cancel(cancelled)

      assert Meetings.recipients(meeting) == []
    end
  end

  describe "meeting_as_seen_by/2" do
    setup :insert_group_meeting

    test "participant recipient overlays attendee_* fields and seat URLs", %{meeting: meeting} do
      participant =
        insert_participant(meeting, %{
          name: "Overlay Person",
          email: "overlay@example.com",
          phone: "+49 123",
          company: "ACME",
          message: "See you there",
          timezone: "Europe/Kyiv",
          locale: "uk",
          custom_field_answers: %{"q1" => "a1"}
        })

      [recipient] = Meetings.recipients(meeting)
      seen = Meetings.meeting_as_seen_by(meeting, recipient)

      assert seen.attendee_name == "Overlay Person"
      assert seen.attendee_email == "overlay@example.com"
      assert seen.attendee_phone == "+49 123"
      assert seen.attendee_company == "ACME"
      assert seen.attendee_message == "See you there"
      assert seen.attendee_timezone == "Europe/Kyiv"
      assert seen.attendee_locale == "uk"
      assert seen.custom_field_answers == %{"q1" => "a1"}
      assert seen.cancel_url =~ "/seat/#{participant.management_token}/cancel"
      assert seen.reschedule_url =~ "/seat/#{participant.management_token}/reschedule"

      # Untouched meeting-level fields survive the overlay
      assert seen.uid == meeting.uid
      assert seen.organizer_email == meeting.organizer_email
    end

    test "attendee recipient returns the meeting unchanged" do
      meeting = insert(:meeting)
      [recipient] = Meetings.recipients(meeting)

      assert Meetings.meeting_as_seen_by(meeting, recipient) == meeting
    end
  end
end
