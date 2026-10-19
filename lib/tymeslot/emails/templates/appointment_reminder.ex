defmodule Tymeslot.Emails.Templates.AppointmentReminder do
  @moduledoc """
  Email template for appointment reminders sent to attendees, guests and
  organisers. Role-dispatched via `render/3`.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Formatting,
    JoinUrl,
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
    locale = RecipientLocale.attendee_locale(appointment_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details = TemplateHelper.attendee_meeting_details(appointment_details, :attendee)

      mjml_content = """
      #{MeetingComponents.time_alert_badge(@intent, appointment_details.time_until)}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.organizer_note_box(@intent, appointment_details[:organizer_note])}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{if attendee_video_url = JoinUrl.for(:attendee, appointment_details) do
        MeetingComponents.video_meeting_section(@intent, attendee_video_url,
        title: dgettext("emails_booking", "Join when you're ready"),
        button_text: dgettext("emails_booking", "Join Meeting"))
      end}

      #{MeetingComponents.actions_section(@intent, dgettext("emails_booking", "Need to change plans?"), [%{text: dgettext("emails_booking", "Reschedule"), url: Map.get(appointment_details, :reschedule_url), style: :secondary}, %{text: dgettext("emails_booking", "Cancel"), url: Map.get(appointment_details, :cancel_url), style: :danger}])}

      #{Text.centered_text(dgettext("emails_booking", "See you %{time_until}!", time_until: appointment_details.time_until_friendly || dgettext("emails_booking", "soon")), padding: "18px 0 0 0", font_size: "15px")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "Reminder"),
          stage_title: dgettext("emails_booking", "Our meeting is coming up"),
          stage_subtitle:
            dgettext("emails_booking", "Starting in %{time_until}",
              time_until: appointment_details.time_until
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> MjmlEmail.put_reply_to(
        appointment_details.organizer_name,
        appointment_details.organizer_email
      )
      |> subject(
        dgettext("emails_booking", "Reminder: Our meeting is in %{time_until}",
          time_until: appointment_details.time_until
        )
      )
      |> html_body(html_body)
      |> text_body(build_attendee_text_body(appointment_details, meeting_details, locale))
    end)
  end

  def render(:guest, guest_email, appointment_details) do
    # Guests inherit the booker's locale, as their invitation does.
    locale = RecipientLocale.attendee_locale(appointment_details)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      guest_name = Map.get(appointment_details, :guest_name) || guest_email
      guest_video_url = JoinUrl.for(:guest, appointment_details)

      meeting_details = TemplateHelper.attendee_meeting_details(appointment_details, :guest)

      intro_copy =
        dgettext(
          "emails_booking",
          "Hi %{guest} - the meeting with %{organizer} that %{booker} invited you to is coming up.",
          guest: guest_name,
          organizer: appointment_details.organizer_name,
          booker: appointment_details.attendee_name
        )

      mjml_content = """
      #{MeetingComponents.time_alert_badge(@intent, appointment_details.time_until)}

      #{Text.centered_text(intro_copy, padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.organizer_note_box(@intent, appointment_details[:organizer_note])}

      #{if guest_video_url do
        MeetingComponents.video_meeting_section(@intent, guest_video_url,
        title: dgettext("emails_booking", "Join when you're ready"),
        button_text: dgettext("emails_booking", "Join Meeting"))
      end}

      #{MeetingComponents.actions_section(@intent, dgettext("emails_booking", "Can you still make it?"), TemplateHelper.guest_answer_actions(appointment_details))}

      #{Text.centered_text(dgettext("emails_booking", "Only %{booker} can move or cancel the meeting itself.", booker: appointment_details.attendee_name), font_size: "14px", padding: "16px 0 0 0")}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "Reminder"),
          stage_title: dgettext("emails_booking", "The meeting is coming up"),
          stage_subtitle:
            dgettext("emails_booking", "Meeting with %{name}",
              name: appointment_details.organizer_name
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({guest_name, guest_email})
      |> MjmlEmail.put_reply_to(
        appointment_details.organizer_name,
        appointment_details.organizer_email
      )
      |> subject(
        dgettext("emails_booking", "Reminder: the meeting with %{name} is in %{time_until}",
          name: appointment_details.organizer_name,
          time_until: appointment_details.time_until
        )
      )
      |> html_body(html_body)
      |> text_body(
        build_guest_text_body(appointment_details, meeting_details, guest_name, locale)
      )
    end)
  end

  def render(:organizer, organizer_email, appointment_details) do
    appointment_details =
      Map.put(appointment_details, :time_until, organizer_time_until(appointment_details))

    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      meeting_details = TemplateHelper.organizer_meeting_details(appointment_details)

      mjml_content = """
      #{MeetingComponents.meeting_details_table(meeting_details, organizer_locale(appointment_details))}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{MeetingComponents.attendee_info_section(@intent, %{name: appointment_details.attendee_name, email: appointment_details.attendee_email})}

      #{MeetingComponents.attendee_message_box(@intent, appointment_details[:attendee_message])}

      #{if organizer_video_url = JoinUrl.for(:organizer, appointment_details) do
        MeetingComponents.video_meeting_section(@intent, organizer_video_url,
        title: dgettext("emails_booking", "Host video call"),
        button_text: dgettext("emails_booking", "Start Meeting"))
      end}

      #{Text.section_title(dgettext("emails_booking", "Quick prep"))}
      #{Text.bullet_list(organizer_prep_items(appointment_details))}

      #{MeetingComponents.actions_section(@intent, dgettext("emails_booking", "Quick actions"), organizer_actions(appointment_details))}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "Starting soon"),
          stage_title:
            dgettext("emails_booking", "Meeting with %{name}",
              name: appointment_details.attendee_name
            ),
          stage_subtitle:
            dgettext("emails_booking", "Starting in %{time_until}",
              time_until: appointment_details.time_until
            )
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> MjmlEmail.put_reply_to(
        appointment_details.attendee_name,
        appointment_details.attendee_email
      )
      |> subject(
        dgettext("emails_booking", "⏰ Meeting with %{name} in %{time_until}",
          name: appointment_details.attendee_name,
          time_until: appointment_details.time_until
        )
      )
      |> html_body(html_body)
      |> text_body(build_organizer_text_body(appointment_details, meeting_details))
    end)
  end

  # Every action the payload has a link for; the bar leaves out the rest. A
  # group meeting's reminder (`AppointmentBuilder.for_organizer_of_group/3`)
  # carries only the dashboard link, since the public links to reschedule or
  # cancel a booking are refused for a group meeting; a one-to-one booking
  # carries those two and no dashboard link.
  defp organizer_actions(appointment_details) do
    [
      %{
        text: dgettext("emails_booking", "Open in dashboard"),
        url: Map.get(appointment_details, :dashboard_url),
        style: :primary
      },
      %{
        text: dgettext("emails_booking", "Reschedule"),
        url: Map.get(appointment_details, :reschedule_url),
        style: :secondary
      },
      %{
        text: dgettext("emails_booking", "Cancel"),
        url: Map.get(appointment_details, :cancel_url),
        style: :danger
      }
    ]
  end

  defp build_attendee_text_body(appointment_details, meeting_details, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(meeting_details, locale)

    video_section =
      TextBodyHelper.format_video_section(
        JoinUrl.for(:attendee, appointment_details),
        locale
      )

    action_links = TextBodyHelper.format_action_links(appointment_details, locale)
    custom_answers = TextBodyHelper.format_custom_answers(appointment_details, locale)

    """
    #{dgettext("emails_booking", "REMINDER: Our meeting in %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails_booking", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails_booking", "I'm looking forward to our conversation!")}

    #{dgettext("emails_booking", "DETAILS:")}
    #{meeting_details}#{TextBodyHelper.format_organizer_note(appointment_details, locale)}#{video_section}#{custom_answers}
    #{if action_links != "", do: dgettext("emails_booking", "Need to change plans?") <> action_links}

    #{dgettext("emails_booking", "See you %{time_until}!", time_until: appointment_details.time_until_friendly || dgettext("emails_booking", "soon"))}

    #{dgettext("emails_booking", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  defp build_guest_text_body(appointment_details, meeting_details, guest_name, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(meeting_details, locale)

    video_section =
      TextBodyHelper.format_video_section(JoinUrl.for(:guest, appointment_details), locale)

    """
    #{dgettext("emails_booking", "REMINDER: the meeting is in %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails_booking", "Hi %{guest},", guest: guest_name)}

    #{dgettext("emails_booking", "The meeting with %{organizer} that %{booker} invited you to is coming up.", organizer: appointment_details.organizer_name, booker: appointment_details.attendee_name)}

    #{dgettext("emails_booking", "DETAILS:")}
    #{meeting_details}#{TextBodyHelper.format_organizer_note(appointment_details, locale)}#{video_section}#{TextBodyHelper.format_guest_answers(appointment_details, dgettext("emails_booking", "CAN YOU STILL MAKE IT?"))}

    #{dgettext("emails_booking", "Only %{booker} can move or cancel the meeting itself.", booker: appointment_details.attendee_name)}
    """
  end

  defp build_organizer_text_body(appointment_details, meeting_details) do
    meeting_details =
      TextBodyHelper.format_meeting_details(
        meeting_details,
        organizer_locale(appointment_details)
      )

    attendee_info =
      TextBodyHelper.format_attendee_info(
        appointment_details,
        organizer_locale(appointment_details)
      )

    video_section =
      TextBodyHelper.format_video_section(
        JoinUrl.for(:organizer, appointment_details),
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
    #{dgettext("emails_booking", "STARTING IN %{time_until}", time_until: appointment_details.time_until)}

    #{dgettext("emails_booking", "Meeting with %{name}", name: appointment_details.attendee_name)}

    #{dgettext("emails_booking", "MEETING DETAILS:")}
    #{meeting_details}#{video_section}#{attendee_info}#{custom_answers}

    #{dgettext("emails_booking", "QUICK PREP:")}
    #{TextBodyHelper.format_bullets(organizer_prep_items(appointment_details))}#{action_links}

    #{dgettext("emails_booking", "Best,")}
    #{appointment_details.organizer_name}
    """
  end

  @doc """
  The organiser's quick preparation list, in their locale: the one list both
  the HTML and the plain-text body of their reminder render. A video meeting
  asks for the camera and microphone, any other for the location.
  """
  @spec organizer_prep_items(Tymeslot.Emails.EmailService.appointment_details()) :: [
          String.t()
        ]
  def organizer_prep_items(appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      [
        if(Sanitise.safe_web_url?(JoinUrl.for(:organizer, appointment_details)),
          do: dgettext("emails_booking", "Camera & mic ready"),
          else: dgettext("emails_booking", "Location confirmed")
        ),
        dgettext("emails_booking", "Materials prepared"),
        dgettext("emails_booking", "Agenda ready")
      ]
    end)
  end

  # The payload's `time_until` is already formatted in the attendee's
  # language, so the organiser's copy is formatted again in theirs. A payload
  # without the raw reminder (a legacy free-text label) keeps its own.
  defp organizer_time_until(%{reminder_raw: %{value: _value, unit: _unit} = raw} = details),
    do: Formatting.format_reminder_label(raw, organizer_locale(details))

  defp organizer_time_until(details), do: details.time_until

  defp organizer_locale(appointment_details),
    do: RecipientLocale.organizer_locale(appointment_details)
end
