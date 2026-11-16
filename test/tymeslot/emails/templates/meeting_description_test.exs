defmodule Tymeslot.Emails.Templates.MeetingDescriptionTest do
  @moduledoc """
  The confirmation and the reminder show the description the organiser wrote
  for the meeting, to every recipient, in both parts of the email; and say
  nothing about it when there is none. The generic preparation checklists
  they used to carry are gone.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.{AppointmentConfirmation, AppointmentReminder}

  @description "Bring your passport\nand the signed contract"

  @renders [
    {"confirmation to the attendee", AppointmentConfirmation, :attendee},
    {"confirmation to a guest", AppointmentConfirmation, :guest},
    {"confirmation to the organiser", AppointmentConfirmation, :organizer},
    {"reminder to the attendee", AppointmentReminder, :attendee},
    {"reminder to a guest", AppointmentReminder, :guest},
    {"reminder to the organiser", AppointmentReminder, :organizer}
  ]

  for {label, template, role} <- @renders do
    describe label do
      @template template
      @role role

      test "shows the description in HTML and text" do
        email =
          @template.render(
            @role,
            "someone@example.com",
            build_appointment_details(%{description: @description})
          )

        assert email.html_body =~ "Bring your passport<br"
        assert email.html_body =~ "and the signed contract"
        assert email.text_body =~ "DESCRIPTION:\n#{@description}"
      end

      test "leaves the section out when there is no description" do
        for description <- [nil, "", "  \n "] do
          email =
            @template.render(
              @role,
              "someone@example.com",
              build_appointment_details(%{description: description})
            )

          refute email.text_body =~ "DESCRIPTION:"
          refute email.html_body =~ ~r/>\s*Description\s*</
        end
      end

      test "carries no generic preparation checklist" do
        email = @template.render(@role, "someone@example.com", build_appointment_details(%{}))

        for gone <- [
              "PREPARATION REMINDERS",
              "QUICK PREP",
              "Materials prepared",
              "Set a reminder"
            ] do
          refute email.text_body =~ gone
          refute email.html_body =~ gone
        end
      end
    end
  end
end
