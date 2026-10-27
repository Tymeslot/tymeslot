defmodule Tymeslot.Emails.Templates.OrganizerPrepChecklistTest do
  @moduledoc """
  The organiser's preparation checklist reads the same in both parts of the
  email: the HTML and the plain text render one list of items, kept once per
  template.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Shared.Sanitise
  alias Tymeslot.Emails.Templates.{AppointmentConfirmation, AppointmentReminder}

  defp assert_both_parts_list(email, items) do
    assert items != []

    assert Enum.reject(items, &(email.html_body =~ Sanitise.sanitize_for_email(&1))) == []
    assert Enum.reject(items, &(email.text_body =~ "• #{&1}")) == []
  end

  describe "AppointmentConfirmation to the organiser" do
    test "lists the preparation reminders in HTML and text" do
      details = build_appointment_details(%{reminder_raw: %{value: 30, unit: "minutes"}})
      email = AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Preparation reminders"

      assert_both_parts_list(email, [
        "Review any relevant materials",
        "Prepare an agenda if needed",
        "Test video/audio setup if virtual",
        "Set a reminder 30 minutes before"
      ])

      assert_both_parts_list(email, AppointmentConfirmation.organizer_prep_items(details))
    end

    test "says no reminder is scheduled when reminders are off" do
      details = build_appointment_details(%{reminders_enabled: false})
      email = AppointmentConfirmation.render(:organizer, "organizer@example.com", details)

      assert_both_parts_list(email, ["No reminder emails are scheduled for this appointment"])
      refute email.text_body =~ "Set a reminder"
    end
  end

  describe "AppointmentReminder to the organiser" do
    test "lists the quick prep for a video meeting in HTML and text" do
      details = build_appointment_details(%{})
      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert email.html_body =~ "Quick prep"
      assert_both_parts_list(email, ["Camera & mic ready", "Materials prepared", "Agenda ready"])
      assert_both_parts_list(email, AppointmentReminder.organizer_prep_items(details))
    end

    test "asks for the location instead of the camera for an in-person meeting" do
      details =
        build_appointment_details(%{
          meeting_url: nil,
          organizer_video_url: nil,
          attendee_video_url: nil
        })

      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert_both_parts_list(email, ["Location confirmed"])
      refute email.text_body =~ "Camera"
    end

    test "asks for the location when the only join link is not a web address" do
      details =
        build_appointment_details(%{
          meeting_url: nil,
          organizer_video_url: "javascript:alert(1)",
          attendee_video_url: nil
        })

      email = AppointmentReminder.render(:organizer, "organizer@example.com", details)

      assert_both_parts_list(email, ["Location confirmed"])
      refute email.html_body =~ "Camera"
    end
  end
end
