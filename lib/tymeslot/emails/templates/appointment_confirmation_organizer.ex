defmodule Tymeslot.Emails.Templates.AppointmentConfirmationOrganizer do
  @moduledoc """
  Email module for sending appointment confirmations to the organizer (you).
  """

  import Swoosh.Email
  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Locales

  alias Tymeslot.Emails.Shared.{
    Components,
    MjmlEmail,
    SharedHelpers,
    TemplateHelper,
    TextBodyHelper
  }

  use Gettext, backend: TymeslotWeb.Gettext

  @spec confirmation_email(String.t(), map()) :: Swoosh.Email.t()
  def confirmation_email(organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(), fn ->
      mjml_content = """
      #{Components.title_section(dgettext("emails", "New Appointment Booked!"),
      emoji: "🎉",
      subtitle: dgettext("emails", "%{name} has scheduled a meeting with you.", name: appointment_details.attendee_name),
      align: "left")}

      #{Components.attendee_info_section(%{name: appointment_details.attendee_name, email: appointment_details.attendee_email, notes: appointment_details.attendee_message})}

      #{Components.section_title(dgettext("emails", "Meeting Details"), padding: "16px 0 16px 0")}

      #{Components.meeting_details_table(%{date: appointment_details.date, start_time: appointment_details.start_time_owner_tz, duration: appointment_details.duration, location: appointment_details.location, location_type: Map.get(appointment_details, :location_type), meeting_type: appointment_details.meeting_type, video_url: Map.get(appointment_details, :meeting_url), video_url_role: "host"}, organizer_locale())}

      #{Components.section_title(dgettext("emails", "Need to make changes?"))}

      #{Components.meeting_actions_bar([%{text: dgettext("emails", "Reschedule"), url: appointment_details.reschedule_url, style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: appointment_details.cancel_url, style: :danger}])}
      """

      organizer_details = TemplateHelper.build_organizer_details(appointment_details)
      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        dgettext("emails", "New Appointment: %{name} - %{date}",
          name: appointment_details.attendee_name,
          date: SharedHelpers.format_date_short(appointment_details.date, organizer_locale())
        )
      )
      |> html_body(html_body)
      |> text_body(text_body(appointment_details))
      |> attachment(
        IcsGenerator.generate_ics_attachment(
          appointment_details,
          organizer_locale(),
          "appointment-#{appointment_details.uid}.ics"
        )
      )
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
    #{dgettext("emails", "New Appointment Booked!")}

    #{dgettext("emails", "%{name} has scheduled a meeting with you.", name: appointment_details.attendee_name)}#{attendee_info}

    #{dgettext("emails", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{action_links}

    #{dgettext("emails", "PREPARATION REMINDERS:")}
    #{dgettext("emails", "- Review any relevant materials")}
    #{dgettext("emails", "- Prepare an agenda if needed")}
    #{dgettext("emails", "- Test video/audio setup if virtual")}
    #{organizer_reminder_line(appointment_details)}

    Best,
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
        SharedHelpers.format_duration(
          reminder_to_minutes(value, unit),
          organizer_locale()
        )

      _other ->
        dgettext("emails", "15 minutes")
    end
  end

  defp reminder_to_minutes(value, "hours"), do: value * 60
  defp reminder_to_minutes(value, "days"), do: value * 60 * 24
  defp reminder_to_minutes(value, _unit), do: value

  defp organizer_locale, do: Locales.default_locale()
end
