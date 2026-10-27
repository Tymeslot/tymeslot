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

  describe "validate/2" do
    test "a complete one-to-one meeting can be emailed" do
      assert Recipients.validate(meeting_with_organizer()) == :ok
      assert Recipients.validate(meeting_with_organizer(), :recipients) == :ok
    end

    for field <- [:organizer_name, :organizer_email, :attendee_name, :attendee_email] do
      test "a one-to-one meeting without #{field} is refused, by its field name" do
        meeting = meeting_with_organizer(%{unquote(field) => nil})

        assert Recipients.validate(meeting, :recipients) ==
                 {:error, "Missing meeting fields: #{unquote(field)}"}
      end
    end

    test "a booking also needs its calendar event and its start" do
      meeting = meeting_with_organizer(%{calendar_uid: nil, start_time: nil})

      assert {:error, "Missing meeting fields: calendar_uid, start_time"} =
               Recipients.validate(meeting)

      # Cancellation asks only for who to tell.
      assert Recipients.validate(meeting, :recipients) == :ok
    end

    test "a group meeting is not asked for an attendee its row cannot carry" do
      meeting = meeting_with_organizer(%{capacity: 5, attendee_name: nil, attendee_email: nil})

      assert Recipients.validate(meeting) == :ok

      assert {:error, "Missing meeting fields: organizer_email"} =
               Recipients.validate(%{meeting | organizer_email: nil})
    end
  end
end
