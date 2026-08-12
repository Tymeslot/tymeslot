defmodule Tymeslot.Emails.Templates.AppointmentRescheduled do
  @moduledoc """
  Email template for a meeting that has moved to a new time. Role-dispatched
  via `render/3`.

  A reschedule is a change to a booking both sides already have on file, so the
  email leads with the new slot and states the one it replaces, and its ICS
  attachment carries the next SEQUENCE so calendar clients supersede the entry
  they already hold rather than adding a second one.

  The reschedule context (`:original_start_time` and friends) is supplied by
  `Tymeslot.Notifications.ContentBuilder.build_reschedule_details/2`. Every key
  it adds is read defensively here: a payload without it still renders, minus
  the "previously" line.
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

  # A reschedule asks for attention: the time both sides had is no longer the
  # time that stands.
  @intent :alert

  @spec render(
          :attendee | :organizer,
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) :: Swoosh.Email.t()
  def render(:attendee, attendee_email, appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_video_url = join_url(:attendee, appointment_details)

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
          "Hi %{name} - our appointment has been moved. Here's the new time, and my calendar is already updated.",
          name: appointment_details.attendee_name
        )

      mjml_content = """
      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{previous_time_callout(appointment_details, :attendee, locale)}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if attendee_video_url do
        MeetingComponents.video_meeting_section(@intent, attendee_video_url,
        title: dgettext("emails", "Same link, new time"),
        button_text: dgettext("emails", "Join Video Meeting"))
      end}

      #{Text.section_title(dgettext("emails", "Does the new time not work?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}

      #{reminders_callout(appointment_details)}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Rescheduled"),
          stage_title: dgettext("emails", "Your meeting has moved."),
          stage_subtitle:
            dgettext("emails", "Meeting with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Meeting Rescheduled - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_attendee_text_body(appointment_details, locale))
      |> attachment(update_ics_attachment(appointment_details, locale))
    end)
  end

  def render(:organizer, organizer_email, appointment_details) do
    locale = organizer_locale(appointment_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      organizer_video_url = join_url(:organizer, appointment_details)

      mjml_content = """
      #{MeetingComponents.attendee_info_section(@intent, %{name: appointment_details.attendee_name, email: appointment_details.attendee_email})}

      #{previous_time_callout(appointment_details, :organizer, locale)}

      #{MeetingComponents.meeting_details_table(TemplateHelper.organizer_meeting_details(appointment_details), locale)}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if organizer_video_url do
        MeetingComponents.video_meeting_section(@intent, organizer_video_url,
        title: dgettext("emails", "Host video call"),
        button_text: dgettext("emails", "Start Meeting"))
      end}

      #{Text.section_title(dgettext("emails", "Need to make changes?"))}

      #{MeetingComponents.meeting_actions_bar(@intent, [%{text: dgettext("emails", "Reschedule"), url: Map.get(appointment_details, :reschedule_url, "#"), style: :secondary}, %{text: dgettext("emails", "Cancel Appointment"), url: Map.get(appointment_details, :cancel_url, "#"), style: :danger}])}

      #{Text.system_footer_note(dgettext("emails", "The attendee has been notified of the new time."))}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails", "Rescheduled"),
          stage_title: dgettext("emails", "Meeting rescheduled"),
          stage_subtitle:
            dgettext("emails", "%{name} has moved your meeting.",
              name: appointment_details.attendee_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      # No ICS attachment for the organiser, for the same reason confirmations
      # omit it: Tymeslot writes the new time straight to the organiser's own
      # calendar, and an iMIP-aware mail server would import the attachment on
      # top of that as a second event.
      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Rescheduled: %{name} - %{date}",
            name: appointment_details.attendee_name,
            date: Formatting.format_date_short(appointment_details.date, locale)
          )
        )
      )
      |> html_body(html_body)
      |> text_body(build_organizer_text_body(appointment_details))
    end)
  end

  # The slot this booking used to occupy, rendered in the recipient's own
  # timezone. Returns "" when the payload carries no reschedule context, so the
  # template degrades to a plain "new details" email instead of raising.
  defp previous_time_callout(appointment_details, recipient, locale) do
    case previous_start_time(appointment_details, recipient) do
      nil ->
        ""

      previous ->
        Callouts.alert_box(@intent, Formatting.format_datetime(previous, locale),
          title: dgettext("emails", "Previously scheduled for")
        )
    end
  end

  defp previous_time_line(appointment_details, recipient, locale) do
    case previous_start_time(appointment_details, recipient) do
      nil ->
        ""

      previous ->
        "\n#{dgettext("emails", "Previously scheduled for")}: #{Formatting.format_datetime(previous, locale)}\n"
    end
  end

  defp previous_start_time(appointment_details, :attendee) do
    Map.get(appointment_details, :original_start_time_attendee_tz) ||
      Map.get(appointment_details, :original_start_time)
  end

  defp previous_start_time(appointment_details, :organizer) do
    Map.get(appointment_details, :original_start_time_owner_tz) ||
      Map.get(appointment_details, :original_start_time)
  end

  # Read defensively: a payload built without reminder details must still
  # render. See the module doc.
  defp reminders_callout(appointment_details) do
    case Map.get(appointment_details, :reminders_summary) do
      nil ->
        ""

      summary ->
        Callouts.alert_box(@intent, summary, title: dgettext("emails", "Reminders Scheduled"))
    end
  end

  # A reschedule supersedes an invitation the attendee's calendar already
  # holds, so the SEQUENCE moves past the last one sent. Same reasoning, and
  # the same METHOD:PUBLISH-not-REQUEST caution, as the cancellation ICS.
  defp update_ics_attachment(appointment_details, locale) do
    current_sequence = Map.get(appointment_details, :ical_sequence) || 0

    IcsGenerator.generate_ics_update_attachment(
      appointment_details,
      current_sequence + 1,
      locale,
      "appointment-#{appointment_details.uid}.ics"
    )
  end

  defp build_attendee_text_body(appointment_details, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(join_url(:attendee, appointment_details), locale)

    action_links = TextBodyHelper.format_action_links(appointment_details, locale)
    custom_answers = TextBodyHelper.format_custom_answers(appointment_details, locale)
    reminders = Map.get(appointment_details, :reminders_summary)

    """
    #{dgettext("emails", "Meeting Rescheduled")}

    #{dgettext("emails", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails", "Our appointment has been moved. Here's the new time, and my calendar is already updated.")}
    #{previous_time_line(appointment_details, :attendee, locale)}
    #{dgettext("emails", "NEW MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}
    #{action_links}
    #{if reminders, do: "\n#{reminders}\n", else: ""}
    #{dgettext("emails", "Looking forward to meeting you!")}
    #{appointment_details.organizer_name}
    """
  end

  defp build_organizer_text_body(appointment_details) do
    appointment_details = TemplateHelper.as_organizer_view(appointment_details)
    locale = organizer_locale(appointment_details)

    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)
    attendee_info = TextBodyHelper.format_attendee_info(appointment_details, locale)

    video_section =
      TextBodyHelper.format_video_section(join_url(:organizer, appointment_details), locale)

    action_links = TextBodyHelper.format_action_links(appointment_details, locale)
    custom_answers = TextBodyHelper.format_custom_answers(appointment_details, locale)

    """
    #{dgettext("emails", "Meeting Rescheduled")}

    #{dgettext("emails", "%{name} has moved your meeting.", name: appointment_details.attendee_name)}#{attendee_info}
    #{previous_time_line(appointment_details, :organizer, locale)}
    #{dgettext("emails", "NEW MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{custom_answers}#{action_links}

    #{dgettext("emails", "The attendee has been notified of the new time.")}
    """
  end

  # Same per-role join URL rules as the confirmation email; see the note there.
  defp join_url(:organizer, details) do
    Map.get(details, :organizer_video_url) || Map.get(details, :meeting_url)
  end

  defp join_url(:attendee, details), do: Map.get(details, :attendee_video_url)

  defp organizer_locale(_appointment_details), do: Locales.default_locale()
end
