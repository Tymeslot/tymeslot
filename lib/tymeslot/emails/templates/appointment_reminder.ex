defmodule Tymeslot.Emails.Templates.AppointmentReminder do
  @moduledoc """
  Email template for appointment reminders sent to attendees and organisers.
  Role-dispatched via `render/3`.
  """

  import Swoosh.Email

  alias Tymeslot.Locales

  alias Tymeslot.Emails.Shared.{
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  # A reminder email is an informational nudge about something upcoming.
  @intent :confirmed

  @spec render(
          :attendee | :organizer,
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) :: Swoosh.Email.t()
  def render(:attendee, attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details = %{
        date: appointment_details.date,
        start_time: appointment_details.start_time_attendee_tz,
        duration: appointment_details.duration,
        location: appointment_details.location,
        location_type: Map.get(appointment_details, :location_type),
        meeting_type: appointment_details.meeting_type,
        timezone: appointment_details.attendee_timezone
      }

      mjml_content = """
      #{MeetingComponents.time_alert_badge(@intent, appointment_details.time_until)}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if Map.get(appointment_details, :meeting_url) do
        MeetingComponents.video_meeting_section(@intent, appointment_details.meeting_url,
        title: dgettext("emails", "Join when you're ready"),
        button_text: dgettext("emails", "Join Meeting"))
      end}

      #{Text.section_title(dgettext("emails", "Need to change plans?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}

      #{Text.centered_text(dgettext("emails", "See you %{time_until}!", time_until: appointment_details.time_until_friendly || dgettext("emails", "soon")), padding: "18px 0 0 0", font_size: "15px")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Reminder"),
          stage_title: dgettext("emails", "Our meeting is coming up"),
          stage_subtitle:
            dgettext("emails", "Starting %{time_until}",
              time_until: appointment_details.time_until
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Reminder: Our meeting is %{time_until}",
            time_until: appointment_details.time_until
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_attendee_text_body(appointment_details, locale))
    end)
  end

  def render(:organizer, organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      meeting_details = TemplateHelper.organizer_meeting_details(appointment_details)

      mjml_content = """
      #{MeetingComponents.meeting_details_table(meeting_details, organizer_locale(appointment_details))}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{MeetingComponents.attendee_info_section(@intent, %{name: appointment_details.attendee_name, email: appointment_details.attendee_email})}

      #{MeetingComponents.attendee_message_box(@intent, appointment_details[:attendee_message])}

      #{if Map.get(appointment_details, :meeting_url) do
        MeetingComponents.video_meeting_section(@intent, appointment_details.meeting_url,
        title: dgettext("emails", "Host video call"),
        button_text: dgettext("emails", "Start Meeting"))
      end}

      #{Text.section_title(dgettext("emails", "Quick actions"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Starting soon"),
          stage_title:
            dgettext("emails", "Meeting with %{name}", name: appointment_details.attendee_name),
          stage_subtitle:
            dgettext("emails", "Starting in %{time_until}",
              time_until: appointment_details.time_until
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "⏰ Meeting with %{name} in %{time_until}",
            name: appointment_details.attendee_name,
            time_until: appointment_details.time_until
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_organizer_text_body(appointment_details))
    end)
  end

  defp build_attendee_text_body(appointment_details, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(Map.get(appointment_details, :meeting_url), locale)

    action_links = TextBodyHelper.format_action_links(appointment_details, locale)
    custom_answers = TextBodyHelper.format_custom_answers(appointment_details, locale)

    """
    #{dgettext("emails", "REMINDER: Our meeting in %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails", "I'm looking forward to our conversation!")}

    #{dgettext("emails", "DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}
    #{dgettext("emails", "Need to change plans?")}#{action_links}

    #{dgettext("emails", "See you %{time_until}!", time_until: appointment_details.time_until_friendly || dgettext("emails", "soon"))}

    #{dgettext("emails", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp build_organizer_text_body(appointment_details) do
    appointment_details = TemplateHelper.as_organizer_view(appointment_details)

    meeting_details =
      TextBodyHelper.format_meeting_details(
        appointment_details,
        organizer_locale(appointment_details)
      )

    attendee_info =
      TextBodyHelper.format_attendee_info(
        appointment_details,
        organizer_locale(appointment_details)
      )

    video_section =
      TextBodyHelper.format_video_section(
        Map.get(appointment_details, :meeting_url),
        organizer_locale(appointment_details)
      )

    action_links =
      TextBodyHelper.format_action_links(
        appointment_details,
        organizer_locale(appointment_details)
      )

    custom_answers =
      TextBodyHelper.format_custom_answers(
        appointment_details,
        organizer_locale(appointment_details)
      )

    """
    #{dgettext("emails", "STARTING IN %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails", "Meeting with %{name}", name: appointment_details.attendee_name)}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{attendee_info}#{custom_answers}

    #{dgettext("emails", "QUICK PREP:")}
    #{if Map.get(appointment_details, :meeting_url), do: dgettext("emails", "• Camera & mic ready"), else: dgettext("emails", "• Location confirmed")}
    #{dgettext("emails", "• Materials prepared")}
    #{dgettext("emails", "• Agenda ready")}#{action_links}

    #{dgettext("emails", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp organizer_locale(_appointment_details), do: Locales.admin_default_locale()
end
