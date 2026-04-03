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

  use Gettext, backend: TymeslotWeb.Gettext

  @spec reschedule_request_email(Tymeslot.DatabaseSchemas.MeetingSchema.t()) ::
          Swoosh.Email.t()
  def reschedule_request_email(%Meeting{} = meeting) do
    locale = meeting.attendee_locale || "en"

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      # Convert time to attendee's timezone if available
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)

      meeting_details = %{
        date: attendee_time,
        start_time: attendee_time,
        start_time_attendee_tz: attendee_time,
        duration: meeting.duration,
        location: meeting.location,
        location_type:
          cond do
            meeting.meeting_url -> :video
            meeting.location == "Phone Call" -> :phone
            meeting.location == "In Person" -> :in_person
            true -> :custom
          end,
        meeting_type: meeting.meeting_type || dgettext("emails", "Meeting"),
        timezone: meeting.attendee_timezone || "UTC"
      }

      mjml_content = """
      #{Components.title_section("📅 #{dgettext("emails", "Reschedule Request")}",
      subtitle: dgettext("emails", "Hi %{name}, I need to reschedule our upcoming meeting. Could you please select a new time that works for you?", name: meeting.attendee_name))}
      <mj-section padding="20px 0">
        <mj-column>
          <mj-text font-size="16px" font-weight="600" padding-bottom="10px">
            #{dgettext("emails", "Cancelled Appointment Details")}
          </mj-text>
          #{Components.meeting_details_table(meeting_details, locale)}
        </mj-column>
      </mj-section>
      <mj-section padding="12px 0">
        <mj-column>
          <mj-text font-size="16px" color="#3f3f46" line-height="24px" padding-bottom="16px">
            #{dgettext("emails", "I apologize for any inconvenience this may cause. Your current appointment has been cancelled, and I'd like to help you reschedule at your earliest convenience.")}
          </mj-text>
          <mj-button href="#{meeting.reschedule_url}" background-color="#7c3aed" color="#ffffff" font-size="16px" font-weight="600" padding="20px 0" inner-padding="12px 30px" border-radius="8px">
            #{dgettext("emails", "Choose a New Time")}
          </mj-button>
          <mj-text font-size="14px" color="#52525b" line-height="20px" padding-top="16px">
            #{dgettext("emails", "Once you select a new slot, you'll receive a confirmation email with the updated details. If you have any questions or need to discuss alternative options, please don't hesitate to reach out.")}
          </mj-text>
          <mj-text font-size="14px" color="#52525b" padding-top="12px" align="center">
            #{dgettext("emails", "Thank you for your understanding and flexibility.")}
          </mj-text>
        </mj-column>
      </mj-section>
      """

      html_body = TemplateHelper.compile_system_template(mjml_content)

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> subject(
        dgettext("emails", "Reschedule Request: %{title} - %{date}",
          title: meeting.title,
          date: SharedHelpers.format_date_short(attendee_time, locale)
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(meeting, meeting_details, locale))
    end)
  end

  defp build_text_body(meeting, details, locale) do
    """
    #{dgettext("emails", "Reschedule Request")}

    #{dgettext("emails", "Hi %{name},", name: meeting.attendee_name)}

    #{dgettext("emails", "I need to reschedule our upcoming meeting. Could you please select a new time that works for you?")}

    #{dgettext("emails", "CANCELLED APPOINTMENT DETAILS:")}
    #{dgettext("emails", "Date:")} #{SharedHelpers.format_date_short(details.date, locale)}
    #{dgettext("emails", "Duration:")} #{SharedHelpers.format_duration(details.duration, locale)}
    #{dgettext("emails", "Location:")} #{SharedHelpers.format_location(details)}
    #{dgettext("emails", "Type:")} #{details.meeting_type}
    #{dgettext("emails", "Timezone:")} #{details.timezone}

    #{dgettext("emails", "I apologize for any inconvenience this may cause. Your current appointment has been cancelled, and I'd like to help you reschedule at your earliest convenience.")}

    #{dgettext("emails", "Choose a New Time:")}
    #{meeting.reschedule_url}

    #{dgettext("emails", "Once you select a new slot, you'll receive a confirmation email with the updated details. If you have any questions or need to discuss alternative options, please don't hesitate to reach out.")}

    #{dgettext("emails", "Thank you for your understanding and flexibility.")}
    """
  end
end
