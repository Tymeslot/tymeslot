defmodule Tymeslot.Emails.Templates.AppointmentConfirmationOrganizer do
  @moduledoc """
  Email module for sending appointment confirmations to the organizer (you).
  """

  import Swoosh.Email
  alias Tymeslot.Integrations.Calendar.IcsGenerator

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    TemplateHelper,
    TextBodyHelper
  }

  @spec confirmation_email(String.t(), map()) :: Swoosh.Email.t()
  def confirmation_email(organizer_email, appointment_details) do
    mjml_content = """
    #{Components.title_section("New Appointment Booked!",
    emoji: "🎉",
    subtitle: "#{appointment_details.attendee_name} has scheduled a meeting with you.",
    align: "left")}

    #{Components.attendee_info_section(%{name: appointment_details.attendee_name, email: appointment_details.attendee_email, notes: appointment_details.attendee_message})}

    #{Components.section_title("Meeting Details", padding: "16px 0 16px 0")}

    #{Components.meeting_details_table(%{date: appointment_details.date, start_time: appointment_details.start_time_owner_tz, duration: appointment_details.duration, location: appointment_details.location, meeting_type: appointment_details.meeting_type, video_url: Map.get(appointment_details, :meeting_url), video_url_role: "host"})}

    #{Components.section_title("Need to make changes?")}

    #{Components.meeting_actions_bar([%{text: "Reschedule", url: appointment_details.reschedule_url, style: :secondary}, %{text: "Cancel Appointment", url: appointment_details.cancel_url, style: :danger}])}
    """

    organizer_details = TemplateHelper.build_organizer_details(appointment_details)
    html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

    MjmlEmail.base_email()
    |> to({appointment_details.organizer_name, organizer_email})
    |> subject(
      "New Appointment: #{appointment_details.attendee_name} - #{SharedHelpers.format_date_short(appointment_details.date)}"
    )
    |> html_body(html_body)
    |> text_body(text_body(appointment_details))
    |> attachment(
      IcsGenerator.generate_ics_attachment(
        appointment_details,
        "appointment-#{appointment_details.uid}.ics"
      )
    )
  end

  defp text_body(appointment_details) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details)
    attendee_info = TextBodyHelper.format_attendee_info(appointment_details)

    video_section =
      TextBodyHelper.format_video_section(Map.get(appointment_details, :meeting_url))

    action_links = TextBodyHelper.format_action_links(appointment_details)

    """
    New Appointment Booked!

    #{appointment_details.attendee_name} has scheduled a meeting with me. I'll be ready for them!#{attendee_info}

    MEETING DETAILS:
    #{meeting_details}#{video_section}#{action_links}

    PREPARATION REMINDERS:
    - Review any relevant materials
    - Prepare an agenda if needed
    - Test video/audio setup if virtual
    #{organizer_reminder_line(appointment_details)}

    Best,
    #{appointment_details.organizer_name}
    """
  end

  defp organizer_reminder_line(appointment_details) do
    # Default to reminders being enabled if the flag is not explicitly false
    # Map.get returns nil if key exists with nil value, so we need explicit nil check
    reminders_enabled =
      case Map.get(appointment_details, :reminders_enabled) do
        # Default to enabled when not set
        nil -> true
        false -> false
        true -> true
        # Any other value defaults to enabled
        _other -> true
      end

    if reminders_enabled do
      "- Set a reminder #{appointment_details.reminder_time || "15 minutes"} before"
    else
      "- No reminder emails are scheduled for this appointment"
    end
  end
end
