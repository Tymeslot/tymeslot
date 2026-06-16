defmodule Tymeslot.Emails.ExternalBookingChangeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails

  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Emails.Templates.ExternalBookingChange
  alias Tymeslot.Meetings.MeetingSchema

  defp build_meeting(overrides \\ %{}) do
    defaults = %{
      id: 1,
      title: "Team Standup",
      organizer_name: "John Doe",
      organizer_email: "john@example.com",
      organizer_title: "Engineer",
      organizer_user_id: nil,
      start_time: ~U[2026-04-01 10:00:00Z],
      end_time: ~U[2026-04-01 10:30:00Z],
      duration: 30,
      location: "Video Call",
      meeting_type: "Standup",
      meeting_url: "https://meet.example.com/abc",
      view_url: "https://tymeslot.example.com/meetings/abc"
    }

    struct!(MeetingSchema, Map.merge(defaults, overrides))
  end

  describe "ExternalBookingChange.render/4" do
    test "builds email for deleted discrepancy" do
      meeting = build_meeting()

      email =
        ExternalBookingChange.render(
          meeting,
          "john@example.com",
          :deleted,
          "Europe/London"
        )

      assert email.subject =~ "deleted"
      assert email.text_body =~ "deleted"
      assert [{_name, "john@example.com"}] = email.to
    end

    test "builds email for modified discrepancy" do
      meeting = build_meeting()

      email =
        ExternalBookingChange.render(
          meeting,
          "john@example.com",
          :modified,
          "Europe/London"
        )

      assert email.subject =~ "rescheduled"
      assert email.text_body =~ "rescheduled"
    end

    test "uses organizer_name when present" do
      meeting = build_meeting(%{organizer_name: "Jane Smith"})

      email =
        ExternalBookingChange.render(
          meeting,
          "jane@example.com",
          :deleted,
          "UTC"
        )

      assert [{"Jane Smith", "jane@example.com"}] = email.to
    end

    test "falls back to 'Meeting' when title is nil" do
      meeting = build_meeting(%{title: nil})

      email =
        ExternalBookingChange.render(
          meeting,
          "john@example.com",
          :deleted,
          "UTC"
        )

      refute email.subject =~ "nil"
      refute email.html_body =~ ~s("nil")
      refute email.text_body =~ ~s("nil")
      assert email.subject =~ "Meeting"
    end

    test "delivers to the bare email when organizer_name is nil (no placeholder name)" do
      meeting = build_meeting(%{organizer_name: nil})

      email =
        ExternalBookingChange.render(
          meeting,
          "jane@example.com",
          :deleted,
          "UTC"
        )

      assert [{"", "jane@example.com"}] = email.to
    end
  end

  describe "subject CRLF injection prevention" do
    test "subject is free of CR/LF when meeting title contains header-injection payload" do
      meeting = build_meeting(%{title: "Team Standup\r\nBcc: attacker@evil.com"})

      email =
        ExternalBookingChange.render(
          meeting,
          "john@example.com",
          :deleted,
          "Europe/London"
        )

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end
  end

  describe "EmailService.send_external_booking_change/3" do
    test "delivers deleted notification" do
      user = insert(:user)
      insert(:profile, user: user)
      meeting = insert(:meeting, organizer_user: user)

      assert {:ok, _email} =
               EmailService.send_external_booking_change(
                 meeting,
                 user.email,
                 :deleted
               )
    end

    test "delivers modified notification" do
      user = insert(:user)
      insert(:profile, user: user)
      meeting = insert(:meeting, organizer_user: user)

      assert {:ok, _email} =
               EmailService.send_external_booking_change(
                 meeting,
                 user.email,
                 :modified
               )
    end
  end
end
