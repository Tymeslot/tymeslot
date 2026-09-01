defmodule Tymeslot.Notifications.RecipientsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.Notifications.Recipients
  alias Tymeslot.Profiles

  defp meeting_with_organizer(attrs \\ %{}) do
    user = insert(:user)
    insert(:profile, user: user, timezone: "Europe/London")

    meeting =
      build(:meeting, %{
        organizer_user_id: user.id,
        organizer_name: "Alice Organizer",
        organizer_email: "alice@example.com",
        attendee_name: "Bob Attendee",
        attendee_email: "bob@example.com",
        attendee_timezone: "America/New_York"
      })

    struct!(meeting, attrs)
  end

  describe "determine_recipients/2" do
    test "confirmation, reminder, cancellation, and reschedule go to both" do
      meeting = meeting_with_organizer()

      for type <- [:confirmation, :reminder, :cancellation, :reschedule] do
        assert {:both, %{organizer: organizer, attendee: attendee}} =
                 Recipients.determine_recipients(meeting, type)

        assert organizer.name == "Alice Organizer"
        assert attendee.name == "Bob Attendee"
      end
    end

    test "unknown notification type defaults to both recipients" do
      meeting = meeting_with_organizer()

      assert {:both, _recipients} = Recipients.determine_recipients(meeting, :something_new)
    end

    test "organiser participant uses the organiser's profile timezone" do
      meeting = meeting_with_organizer()

      assert {:both, %{organizer: %{timezone: "Europe/London"}}} =
               Recipients.determine_recipients(meeting, :confirmation)
    end

    test "attendee participant uses attendee_timezone when set" do
      meeting = meeting_with_organizer(%{attendee_timezone: "Asia/Tokyo"})

      assert {:both, %{attendee: %{timezone: "Asia/Tokyo"}}} =
               Recipients.determine_recipients(meeting, :confirmation)
    end

    test "attendee participant falls back to organiser timezone when attendee_timezone is nil" do
      meeting = meeting_with_organizer(%{attendee_timezone: nil})

      assert {:both, %{attendee: %{timezone: "Europe/London"}}} =
               Recipients.determine_recipients(meeting, :confirmation)
    end
  end

  describe "get_organizer_timezone/1" do
    test "returns the organiser's profile timezone" do
      meeting = meeting_with_organizer()
      assert Recipients.get_organizer_timezone(meeting) == "Europe/London"
    end

    test "falls back to the system default when organizer_user_id is nil" do
      meeting = meeting_with_organizer(%{organizer_user_id: nil})

      assert Recipients.get_organizer_timezone(meeting) == Profiles.get_default_timezone()
    end

    test "falls back to the system default when organiser has no profile" do
      orphan_user = insert(:user)
      meeting = meeting_with_organizer(%{organizer_user_id: orphan_user.id})

      assert Recipients.get_organizer_timezone(meeting) == Profiles.get_default_timezone()
    end
  end

  describe "get_attendee_timezone/1" do
    test "returns attendee_timezone when populated" do
      meeting = meeting_with_organizer(%{attendee_timezone: "Australia/Sydney"})

      assert Recipients.get_attendee_timezone(meeting) == "Australia/Sydney"
    end

    test "falls back to organiser timezone when attendee_timezone is nil" do
      meeting = meeting_with_organizer(%{attendee_timezone: nil})

      assert Recipients.get_attendee_timezone(meeting) == "Europe/London"
    end
  end

  describe "build_recipient_context/2" do
    test "builds organiser context with organiser fields and timezone" do
      meeting = meeting_with_organizer()

      context = Recipients.build_recipient_context(meeting, :organizer)

      assert context.recipient_type == :organizer
      assert context.recipient_name == "Alice Organizer"
      assert context.recipient_email == "alice@example.com"
      assert context.recipient_timezone == "Europe/London"
      assert context.meeting_id == meeting.id
      assert context.organizer_email == "alice@example.com"
      assert context.attendee_email == "bob@example.com"
    end

    test "builds attendee context with attendee fields and timezone" do
      meeting = meeting_with_organizer()

      context = Recipients.build_recipient_context(meeting, :attendee)

      assert context.recipient_type == :attendee
      assert context.recipient_name == "Bob Attendee"
      assert context.recipient_email == "bob@example.com"
      assert context.recipient_timezone == "America/New_York"
    end
  end

  describe "validate_recipients/1" do
    test "accepts a complete :both pair" do
      meeting = meeting_with_organizer()
      recipients = Recipients.determine_recipients(meeting, :confirmation)

      assert Recipients.validate_recipients(recipients) == :ok
    end

    test "rejects when the organiser is missing an email" do
      meeting = meeting_with_organizer(%{organizer_email: nil})
      recipients = Recipients.determine_recipients(meeting, :confirmation)

      assert {:error, message} = Recipients.validate_recipients(recipients)
      assert message =~ "organizer"
      assert message =~ "email"
    end

    test "rejects when the attendee is missing required fields" do
      meeting = meeting_with_organizer(%{attendee_name: nil})
      recipients = Recipients.determine_recipients(meeting, :confirmation)

      assert {:error, message} = Recipients.validate_recipients(recipients)
      assert message =~ "attendee"
      assert message =~ "name"
    end

    test "rejects an unknown recipient structure" do
      assert {:error, "Invalid recipient structure"} =
               Recipients.validate_recipients(:not_a_tuple)
    end
  end
end
