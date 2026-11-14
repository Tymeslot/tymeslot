defmodule Tymeslot.Notifications.ContentBuilderTest do
  @moduledoc "Verifies meeting content preserves its sender, location and calendar identity."

  use Tymeslot.DataCase, async: true

  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Notifications.ContentBuilder

  describe "build_appointment_details/1" do
    test "includes attendee_locale from the meeting" do
      meeting = build(:meeting, attendee_locale: "fr")
      details = ContentBuilder.build_appointment_details(meeting)
      assert details.attendee_locale == "fr"
    end

    test "defaults attendee_locale to en when nil" do
      meeting = build(:meeting, attendee_locale: nil)
      details = ContentBuilder.build_appointment_details(meeting)
      assert details.attendee_locale == "en"
    end

    test "custom SMTP preserves the named place, video room and real calendar organizer" do
      owner = insert(:user)

      sender = %Sender{
        kind: :user_smtp,
        owner_id: owner.id,
        settings_id: 42,
        revision: 3,
        from_name: "Appointments",
        from_address: "bookings@brand.example.com"
      }

      meeting =
        build(:meeting,
          organizer_user_id: owner.id,
          organizer_email: owner.email,
          email_sender: sender,
          location_kind: :in_person,
          location: "Head office (Main St 1)",
          meeting_url: "https://meet.example.com/room123"
        )

      for details <- [
            ContentBuilder.build_appointment_details(meeting),
            AppointmentBuilder.from_meeting(meeting)
          ] do
        assert details.email_sender == sender
        assert details.location == meeting.location
        assert details.location_type == :in_person
        assert details.meeting_url == meeting.meeting_url

        ics =
          details |> IcsGenerator.generate_ics() |> LineFolder.unfold_lines() |> Enum.join("\n")

        assert ics =~ ~r/^LOCATION(?:;[^:]*)?:Head office \(Main St 1\)$/m
        assert ics =~ ~r/^CONFERENCE;.*:https:\/\/meet\.example\.com\/room123$/m
        assert ics =~ ~r/^ORGANIZER;.*mailto:#{Regex.escape(owner.email)}$/m
        refute ics =~ sender.from_address
      end
    end
  end

  describe "build_appointment_details/1 organiser avatar" do
    test "is an absolute URL to the uploaded avatar" do
      user = insert(:user)
      profile = insert(:profile, user: user, avatar: "photo.png")

      details =
        ContentBuilder.build_appointment_details(build(:meeting, organizer_user_id: user.id))

      assert details.organizer_avatar_url ==
               "http://localhost:4002/uploads/avatars/#{profile.id}/photo.png"
    end

    test "is nil, not a generated data URI, when the organiser has no uploaded avatar" do
      user = insert(:user)
      insert(:profile, user: user, avatar: nil)

      details =
        ContentBuilder.build_appointment_details(build(:meeting, organizer_user_id: user.id))

      assert details.organizer_avatar_url == nil
    end
  end
end
