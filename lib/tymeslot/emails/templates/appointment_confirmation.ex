defmodule Tymeslot.Emails.Templates.AppointmentConfirmation do
  @moduledoc """
  Email template for appointment confirmations sent to attendees and organisers.
  Role-dispatched via `render/3`.
  """

  import Swoosh.Email

  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Locales

  alias Tymeslot.Emails.Shared.{
    Callouts,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  # A confirmation email announces a positive outcome — the booking is set.
  @intent :confirmed

  @spec render(
          :attendee | :organizer,
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) :: Swoosh.Email.t()
  def render(:attendee, attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_video_url = Map.get(appointment_details, :attendee_video_url)

      meeting_details = %{
        date: appointment_details.date,
        start_time: appointment_details.start_time_attendee_tz,
        duration: appointment_details.duration,
        location: appointment_details.location,
        location_type: Map.get(appointment_details, :location_type),
        meeting_type: appointment_details.meeting_type,
        video_url: attendee_video_url,
        video_url_role: "attendee"
      }

      intro_copy =
        dgettext(
          "emails",
          "Hi %{name} — I've blocked the time on my calendar and I'm looking forward to our meeting.",
          name: appointment_details.attendee_name
        )

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{if attendee_video_url do
        MeetingComponents.video_meeting_section(@intent, attendee_video_url,
        title: dgettext("emails", "Ready to join when it's time?"),
        button_text: dgettext("emails", "Join Video Meeting"))
      end}

      #{Text.section_title(dgettext("emails", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}

      #{if appointment_details.organizer_contact_info do
        Text.centered_text(dgettext("emails", "Questions? %{contact_info}", contact_info: appointment_details.organizer_contact_info), font_size: "14px", padding: "16px 0 0 0")
      end}

      #{if appointment_details.reminders_summary do
        Callouts.alert_box(@intent, appointment_details.reminders_summary, title: dgettext("emails", "Reminders Scheduled"))
      end}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Confirmed"),
          stage_title: dgettext("emails", "You're booked."),
          stage_subtitle:
            dgettext("emails", "Meeting with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Appointment Confirmed - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_attendee_text_body(appointment_details, locale))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          appointment_details,
          locale,
          "appointment-#{appointment_details.uid}.ics"
        )
      )
    end)
  end

  def render(:organizer, organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      mjml_content = """
      #{MeetingComponents.attendee_info_section(@intent, %{name: appointment_details.attendee_name, email: appointment_details.attendee_email})}

      #{MeetingComponents.attendee_message_box(@intent, appointment_details[:attendee_message])}

      #{MeetingComponents.meeting_details_table(%{date: appointment_details.date, start_time: appointment_details.start_time_owner_tz, duration: appointment_details.duration, location: appointment_details.location, location_type: Map.get(appointment_details, :location_type), meeting_type: appointment_details.meeting_type, video_url: Map.get(appointment_details, :meeting_url), video_url_role: "host"}, organizer_locale(appointment_details))}

      #{Text.section_title(dgettext("emails", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "New booking"),
          stage_title: dgettext("emails", "New Appointment Booked!"),
          stage_subtitle:
            dgettext("emails", "%{name} has scheduled a meeting with you.",
              name: appointment_details.attendee_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      # No ICS attachment for the organiser email. The organiser is the
      # calendar owner — Tymeslot already writes the event straight to their
      # CalDAV/OAuth calendar. An iTIP `METHOD:REQUEST` attachment on top of
      # that causes iMIP-aware mail servers (Zimbra, Exchange, iCloud Mail)
      # to auto-import the ICS as if it were an external invitation,
      # producing a duplicate event and re-sending invites to the attendee.
      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "New Appointment: %{name} - %{date}",
            name: appointment_details.attendee_name,
            date:
              Formatting.format_date_short(
                appointment_details.date,
                organizer_locale(appointment_details)
              )
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
      TextBodyHelper.format_video_section(
        Map.get(appointment_details, :attendee_video_url),
        locale
      )

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

  defp build_organizer_text_body(appointment_details) do
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

    """
    #{dgettext("emails", "New Appointment Booked!")}

    #{dgettext("emails", "%{name} has scheduled a meeting with you.", name: appointment_details.attendee_name)}#{attendee_info}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{action_links}

    #{dgettext("emails", "PREPARATION REMINDERS:")}
    #{dgettext("emails", "- Review any relevant materials")}
    #{dgettext("emails", "- Prepare an agenda if needed")}
    #{dgettext("emails", "- Test video/audio setup if virtual")}
    #{organizer_reminder_line(appointment_details)}

    #{dgettext("emails", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp organizer_reminder_line(appointment_details) do
    if Map.get(appointment_details, :reminders_enabled) != false do
      reminder_time = format_reminder_for_organizer(appointment_details)
      dgettext("emails", "- Set a reminder %{time} before", time: reminder_time)
    else
      dgettext("emails", "- No reminder emails are scheduled for this appointment")
    end
  end

  # Format reminder time in organizer's locale, avoiding pre-localized attendee strings
  defp format_reminder_for_organizer(appointment_details) do
    case Map.get(appointment_details, :reminder_raw) do
      %{value: value, unit: unit} ->
        Formatting.format_duration(
          reminder_to_minutes(value, unit),
          organizer_locale(appointment_details)
        )

      _other ->
        dgettext("emails", "15 minutes")
    end
  end

  defp reminder_to_minutes(value, "hours"), do: value * 60
  defp reminder_to_minutes(value, "days"), do: value * 60 * 24
  defp reminder_to_minutes(value, _unit), do: value

  defp organizer_locale(_appointment_details), do: Locales.default_locale()
end
