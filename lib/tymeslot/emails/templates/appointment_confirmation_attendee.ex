defmodule Tymeslot.Emails.Templates.AppointmentConfirmationAttendee do
  @moduledoc """
  Email module for sending appointment confirmations to the attendee (person booking).
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

  use Gettext, backend: TymeslotWeb.Gettext

  @spec confirmation_email(String.t(), map()) :: Swoosh.Email.t()
  def confirmation_email(attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details = %{
        date: appointment_details.date,
        start_time: appointment_details.start_time_attendee_tz,
        duration: appointment_details.duration,
        location: appointment_details.location,
        meeting_type: appointment_details.meeting_type,
        video_url: appointment_details.attendee_video_url,
        video_url_role: "attendee"
      }

      mjml_content = """
      #{Components.title_section(dgettext("emails", "Appointment Confirmed!"),
      emoji: "✓",
      subtitle: dgettext("emails", "Hi %{name}, I'm looking forward to our meeting. I've blocked the time on my calendar and will be ready for you.", name: appointment_details.attendee_name),
      align: "left")}

      #{Components.meeting_details_table(meeting_details, locale)}

      #{if appointment_details.attendee_video_url do
        Components.video_meeting_section(appointment_details.attendee_video_url,
        style: :confirmation,
        title: dgettext("emails", "Ready to Join?"),
        button_text: dgettext("emails", "Join Video Meeting"))
      end}

      #{Components.section_title(dgettext("emails", "Need to make changes?"))}

      #{Components.meeting_actions_bar([%{text: dgettext("emails", "Reschedule"), url: appointment_details.reschedule_url, style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: appointment_details.cancel_url, style: :danger}])}

      #{if appointment_details.organizer_contact_info do
        Components.centered_text(dgettext("emails", "Questions? %{contact_info}", contact_info: appointment_details.organizer_contact_info), font_size: "15px", padding: "12px 0 8px 0")
      end}

      #{if appointment_details.reminders_summary do
        Components.alert_box("info", appointment_details.reminders_summary, icon: "⏰", title: dgettext("emails", "Reminders Scheduled"))
      end}
      """

      organizer_details = TemplateHelper.build_organizer_details(appointment_details)
      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = SharedHelpers.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        dgettext("emails", "Appointment Confirmed - %{date} with %{name}",
          date: date_short,
          name: appointment_details.organizer_name
        )
      )
      |> html_body(html_body)
      |> text_body(build_text_body(appointment_details, locale))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          appointment_details,
          locale,
          "appointment-#{appointment_details.uid}.ics"
        )
      )
    end)
  end

  defp build_text_body(appointment_details, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(appointment_details.attendee_video_url, locale)

    action_links = TextBodyHelper.format_action_links(appointment_details, locale)

    """
    #{dgettext("emails", "Appointment Confirmed!")}

    #{dgettext("emails", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails", "I'm looking forward to our meeting. I've blocked the time on my calendar and will be ready for you.")}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}
    #{action_links}
    #{if appointment_details.organizer_contact_info, do: "\n#{dgettext("emails", "QUESTIONS?")}\n#{appointment_details.organizer_contact_info}\n"}
    #{if appointment_details.reminders_summary, do: "\n#{appointment_details.reminders_summary}\n", else: ""}

    #{dgettext("emails", "Looking forward to meeting you!")}
    #{appointment_details.organizer_name}
    """
  end
end
