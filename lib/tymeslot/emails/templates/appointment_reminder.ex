defmodule Tymeslot.Emails.Templates.AppointmentReminder do
  @moduledoc """
  Email template for appointment reminders sent to attendees, guests and
  organisers. Role-dispatched via `render/3`.
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
          :attendee | :guest | :organizer,
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

  def render(:guest, guest_email, appointment_details) do
    # Guests inherit the booker's locale, as their invitation does.
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      guest_name = Map.get(appointment_details, :guest_name) || guest_email
      guest_video_url = guest_join_url(appointment_details)

      meeting_details = %{
        date: appointment_details.date,
        start_time: appointment_details.start_time_attendee_tz,
        duration: appointment_details.duration,
        location: appointment_details.location,
        location_type: Map.get(appointment_details, :location_type),
        meeting_type: appointment_details.meeting_type,
        timezone: Map.get(appointment_details, :attendee_timezone)
      }

      intro_copy =
        dgettext(
          "emails",
          "Hi %{guest} - the meeting with %{organizer} that %{booker} invited you to is coming up.",
          guest: guest_name,
          organizer: appointment_details.organizer_name,
          booker: appointment_details.attendee_name
        )

      mjml_content = """
      #{MeetingComponents.time_alert_badge(@intent, appointment_details.time_until)}

      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{if guest_video_url do
        MeetingComponents.video_meeting_section(@intent, guest_video_url,
        title: dgettext("emails", "Join when you're ready"),
        button_text: dgettext("emails", "Join Meeting"))
      end}

      #{Text.section_title(dgettext("emails", "Can you still make it?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Yes, I'll attend"), url: Map.get(appointment_details, :guest_accept_url, "#"), style: :secondary}, %{text: dgettext("emails", "Can't make it"), url: Map.get(appointment_details, :guest_decline_url, "#"), style: :danger}])}

      #{Text.centered_text(dgettext("emails", "Only %{booker} can move or cancel the meeting itself.", booker: appointment_details.attendee_name), font_size: "14px", padding: "16px 0 0 0")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Reminder"),
          stage_title: dgettext("emails", "The meeting is coming up"),
          stage_subtitle:
            dgettext("emails", "Meeting with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({guest_name, guest_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Reminder: the meeting with %{name} is in %{time_until}",
            name: appointment_details.organizer_name,
            time_until: appointment_details.time_until
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_guest_text_body(appointment_details, guest_name, locale))
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

  defp build_guest_text_body(appointment_details, guest_name, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(guest_join_url(appointment_details), locale)

    """
    #{dgettext("emails", "REMINDER: the meeting is in %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails", "Hi %{guest},", guest: guest_name)}

    #{dgettext("emails", "The meeting with %{organizer} that %{booker} invited you to is coming up.", organizer: appointment_details.organizer_name, booker: appointment_details.attendee_name)}

    #{dgettext("emails", "DETAILS:")}
    #{meeting_details}#{video_section}

    #{dgettext("emails", "CAN YOU STILL MAKE IT?")}
    #{dgettext("emails", "Yes, I'll attend: %{url}", url: Map.get(appointment_details, :guest_accept_url, "#"))}
    #{dgettext("emails", "Can't make it: %{url}", url: Map.get(appointment_details, :guest_decline_url, "#"))}

    #{dgettext("emails", "Only %{booker} can move or cancel the meeting itself.", booker: appointment_details.attendee_name)}
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

  # A guest has no per-role join URL of their own, so they get the link
  # `Meetings.VideoRooms.guest_join_url/1` builds for a recipient the room
  # cannot name: the room URL on most providers, and on one whose links carry
  # a credential that same URL with a token naming nobody, which is the only
  # link a server enforcing tokens will admit. A payload built before that key
  # existed still has the room URL to fall back on.
  #
  # The organiser and attendee bodies above deliberately keep reading
  # `meeting_url`; giving them their own per-role link is a separate change.
  defp guest_join_url(appointment_details) do
    Map.get(appointment_details, :guest_video_url) ||
      Map.get(appointment_details, :meeting_url)
  end

  defp organizer_locale(_appointment_details), do: Locales.admin_default_locale()
end
