defmodule Tymeslot.Emails.Templates.RescheduleRequest do
  @moduledoc """
  Email template for requesting an attendee to reschedule their appointment.
  """

  import Swoosh.Email
  alias Tymeslot.DatabaseSchemas.MeetingSchema, as: Meeting

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    TemplateHelper,
    TimezoneHelper
  }

  @spec reschedule_request_email(Tymeslot.DatabaseSchemas.MeetingSchema.t()) ::
          Swoosh.Email.t()
  def reschedule_request_email(%Meeting{} = meeting) do
    # Convert time to attendee's timezone if available
    attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)

    meeting_details = %{
      date: attendee_time,
      start_time_attendee_tz: attendee_time,
      duration: meeting.duration,
      location: meeting.location || "To be determined",
      meeting_type: meeting.meeting_type || "Meeting",
      timezone: meeting.attendee_timezone || "UTC"
    }

    mjml_content = """
    #{Components.title_section("📅 Reschedule Request",
    subtitle: "Hi #{meeting.attendee_name}, I need to reschedule our upcoming meeting. Could you please select a new time that works for you?")}
    <!-- Cancelled Meeting Details -->
    <mj-section padding="20px 0">
      <mj-column>
        <mj-text font-size="16px" font-weight="600" padding-bottom="10px">
          Cancelled Appointment Details
        </mj-text>
        #{Components.meeting_details_table(meeting_details)}
      </mj-column>
    </mj-section>
    <!-- Call to Action -->
    <mj-section padding="12px 0">
      <mj-column>
        <mj-text font-size="16px" color="#3f3f46" line-height="24px" padding-bottom="16px">
          I apologize for any inconvenience this may cause. Your current appointment has been cancelled, and I'd like to help you reschedule at your earliest convenience.
        </mj-text>
        <mj-button href="#{meeting.reschedule_url}" background-color="#7c3aed" color="#ffffff" font-size="16px" font-weight="600" padding="20px 0" inner-padding="12px 30px" border-radius="8px">
          Choose a New Time
        </mj-button>
        <mj-text font-size="14px" color="#52525b" line-height="20px" padding-top="16px">
          Once you select a new slot, you'll receive a confirmation email with the updated details. If you have any questions or need to discuss alternative options, please don't hesitate to reach out.
        </mj-text>
        <mj-text font-size="14px" color="#52525b" padding-top="12px" align="center">
          Thank you for your understanding and flexibility.
        </mj-text>
      </mj-column>
    </mj-section>
    """

    html_body = TemplateHelper.compile_system_template(mjml_content)

    MjmlEmail.base_email()
    |> to({meeting.attendee_name, meeting.attendee_email})
    |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
    |> subject(
      "Reschedule Request: #{meeting.title} - #{SharedHelpers.format_date_short(attendee_time)}"
    )
    |> html_body(html_body)
  end
end
