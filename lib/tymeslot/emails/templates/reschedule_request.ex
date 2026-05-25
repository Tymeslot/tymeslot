defmodule Tymeslot.Emails.Templates.RescheduleRequest do
  @moduledoc """
  Email template for requesting an attendee to reschedule their appointment.
  """

  import Swoosh.Email
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TimezoneHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  @spec render(Tymeslot.Meetings.MeetingSchema.t()) ::
          Swoosh.Email.t()
  def render(%Meeting{reschedule_url: url} = meeting) when is_binary(url) do
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
      #{Text.section_title(dgettext("emails", "Cancelled Appointment Details"))}
      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{dgettext("emails", "I apologise for any inconvenience this may cause. Your current appointment has been cancelled, and I'd like to help you reschedule at your earliest convenience.")}
      </mj-text>

      #{Buttons.action_button(@intent, dgettext("emails", "Choose a New Time"), meeting.reschedule_url, full_width: true, size: :large)}

      <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="16px 0 0 0">
        #{dgettext("emails", "Once you select a new slot, you'll receive a confirmation email with the updated details. If you have any questions or need to discuss alternative options, please don't hesitate to reach out.")}
      </mj-text>

      #{Text.centered_text(dgettext("emails", "Thank you for your understanding and flexibility."), color: Styles.ink_muted(), font_size: "14px")}
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          dgettext("emails", "Reschedule Request"),
          dgettext(
            "emails",
            "Hi %{name}, I need to reschedule our upcoming meeting. Could you please select a new time that works for you?",
            name: meeting.attendee_name
          ),
          intent: @intent,
          eyebrow: dgettext("emails", "Reschedule"),
          stage_title: dgettext("emails", "Let's find a new time"),
          stage_subtitle:
            dgettext(
              "emails",
              "Hi %{name}, I need to reschedule our upcoming meeting.",
              name: meeting.attendee_name
            )
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Reschedule Request: %{title} - %{date}",
            title: meeting.title,
            date: Formatting.format_date_short(attendee_time, locale)
          )
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
    #{dgettext("emails", "Date:")} #{Formatting.format_date_short(details.date, locale)}
    #{dgettext("emails", "Duration:")} #{Formatting.format_duration(details.duration, locale)}
    #{dgettext("emails", "Location:")} #{Formatting.format_location(details)}
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
