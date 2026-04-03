defmodule Tymeslot.Emails.Templates.AppointmentReminderOrganizer do
  @moduledoc """
  Email module for sending appointment reminders to the organizer.
  """

  import Swoosh.Email

  alias Tymeslot.Locales

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    TemplateHelper,
    TextBodyHelper,
    TimezoneHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @spec reminder_email(
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) :: Swoosh.Email.t()
  def reminder_email(organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(), fn ->
      mjml_content = """
      #{Components.time_alert_badge(dgettext("emails", "Starting in %{time_until}", time_until: appointment_details.time_until), style: :danger)}
      #{Components.title_section(dgettext("emails", "Meeting with %{name}", name: appointment_details.attendee_name), align: "center")}
      #{Components.quick_info_grid([%{label: dgettext("emails", "Time"), value: TimezoneHelper.format_time_owner_tz(appointment_details)}, %{label: dgettext("emails", "Duration"), value: "#{appointment_details.duration} #{dgettext("emails", "min")}"}, %{label: dgettext("emails", "Location"), value: SharedHelpers.format_location(appointment_details)}])}
      <mj-section padding="10px 0 0 0" background-color="#fafafa" border-radius="6px">
        <mj-column>
          <mj-text font-size="13px" font-weight="600" padding="0 0 4px 0" css-class="mobile-text">
            #{SharedHelpers.sanitize_for_email(appointment_details.attendee_name)}
          </mj-text>
          <mj-text font-size="12px" color="#52525b" line-height="16px" css-class="mobile-text">
            #{SharedHelpers.sanitize_for_email(appointment_details.attendee_email)}
          </mj-text>
        </mj-column>
      </mj-section>
      #{Components.attendee_message_box(appointment_details[:attendee_message])}
      #{if Map.get(appointment_details, :meeting_url) do
        Components.video_meeting_section(appointment_details.meeting_url,
        style: :reminder,
        role: "organizer")
      end}
      #{Components.centered_text(dgettext("emails", "Quick actions:"), font_size: "11px", color: "#52525b", padding: "10px 0 6px 0")}
      #{Components.meeting_actions_bar([%{text: dgettext("emails", "Reschedule"), url: appointment_details.reschedule_url, style: :secondary}, %{text: dgettext("emails", "Cancel"), url: appointment_details.cancel_url, style: :danger}])}
      """

      html_body = TemplateHelper.compile_system_template(mjml_content)

      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        dgettext("emails", "⏰ Meeting with %{name} in %{time_until}",
          name: appointment_details.attendee_name,
          time_until: appointment_details.time_until
        )
      )
      |> html_body(html_body)
      |> text_body(text_body(appointment_details))
    end)
  end

  defp text_body(appointment_details) do
    meeting_details =
      TextBodyHelper.format_meeting_details(appointment_details, organizer_locale())

    attendee_info = TextBodyHelper.format_attendee_info(appointment_details, organizer_locale())

    video_section =
      TextBodyHelper.format_video_section(
        Map.get(appointment_details, :meeting_url),
        organizer_locale()
      )

    action_links = TextBodyHelper.format_action_links(appointment_details, organizer_locale())

    """
    #{dgettext("emails", "STARTING IN %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails", "Meeting with %{name}", name: appointment_details.attendee_name)}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{attendee_info}

    #{dgettext("emails", "QUICK PREP:")}
    #{if Map.get(appointment_details, :meeting_url), do: dgettext("emails", "• Camera & mic ready"), else: dgettext("emails", "• Location confirmed")}
    #{dgettext("emails", "• Materials prepared")}
    #{dgettext("emails", "• Agenda ready")}#{action_links}

    #{dgettext("emails", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp organizer_locale, do: Locales.default_locale()
end
