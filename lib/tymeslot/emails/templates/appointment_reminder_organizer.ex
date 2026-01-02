defmodule Tymeslot.Emails.Templates.AppointmentReminderOrganizer do
  @moduledoc """
  Email module for sending appointment reminders to the organizer.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    TemplateHelper,
    TextBodyHelper,
    TimezoneHelper
  }

  @spec reminder_email(String.t(), map()) :: Swoosh.Email.t()
  def reminder_email(organizer_email, appointment_details) do
    mjml_content = """
    <!-- Time Alert -->
    #{Components.time_alert_badge("Starting in #{appointment_details.time_until}", style: :danger)}
    #{Components.title_section("Meeting with #{appointment_details.attendee_name}", align: "center")}
    <!-- Quick Info -->
    #{Components.quick_info_grid([%{label: "Time", value: TimezoneHelper.format_time_owner_tz(appointment_details)}, %{label: "Duration", value: "#{appointment_details.duration} min"}, %{label: "Location", value: appointment_details.location || "Virtual"}])}
    <!-- Attendee Info -->
    <mj-section padding="10px 0 0 0">
      <mj-column>
        <mj-section background-color="#fafafa" border-radius="6px" padding="10px">
          <mj-column>
            <mj-text font-size="13px" font-weight="600" padding="0 0 4px 0" css-class="mobile-text">
              #{appointment_details.attendee_name}
            </mj-text>
            <mj-text font-size="12px" color="#52525b" line-height="16px" css-class="mobile-text">
              #{appointment_details.attendee_email}
            </mj-text>
          </mj-column>
        </mj-section>
        #{Components.attendee_message_box(appointment_details[:attendee_message])}
      </mj-column>
    </mj-section>
    #{if Map.get(appointment_details, :meeting_url) do
      Components.video_meeting_section(appointment_details.meeting_url,
      style: :reminder,
      role: "organizer")
    end}
    <!-- Quick Actions -->
    <mj-text align="center" font-size="11px" color="#52525b" padding="10px 0 6px 0" css-class="mobile-text">
      Quick actions:
    </mj-text>
    #{Components.meeting_actions_bar([%{text: "Reschedule", url: appointment_details.reschedule_url, style: :secondary}, %{text: "Cancel", url: appointment_details.cancel_url, style: :danger}])}
    """

    html_body = TemplateHelper.compile_system_template(mjml_content)

    MjmlEmail.base_email()
    |> to({appointment_details.organizer_name, organizer_email})
    |> subject(
      "⏰ Meeting with #{appointment_details.attendee_name} in #{appointment_details.time_until}"
    )
    |> html_body(html_body)
    |> text_body(text_body(appointment_details))
  end

  defp text_body(appointment_details) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details)
    attendee_info = TextBodyHelper.format_attendee_info(appointment_details)
    video_section = TextBodyHelper.format_video_section(appointment_details.meeting_url)
    action_links = TextBodyHelper.format_action_links(appointment_details)

    """
    STARTING IN #{appointment_details.time_until}

    Meeting with #{appointment_details.attendee_name}

    MEETING DETAILS:
    #{meeting_details}#{video_section}#{attendee_info}

    QUICK PREP:
    #{if appointment_details.meeting_url, do: "• Camera & mic ready", else: "• Location confirmed"}
    • Materials prepared
    • Agenda ready#{action_links}

    Best,
    #{appointment_details.organizer_name}
    """
  end
end
