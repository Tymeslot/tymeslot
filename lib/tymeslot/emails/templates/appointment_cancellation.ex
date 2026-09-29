defmodule Tymeslot.Emails.Templates.AppointmentCancellation do
  @moduledoc """
  Email module for sending appointment cancellation notifications.

  Guests get their own variant: it only states that the meeting they were
  invited to will not take place, without the booker's invitation to book
  again, and its ICS attachment marks the entry in their calendar cancelled.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Templates.AppointmentCancellation.RefundNotice
  alias Tymeslot.Integrations.Calendar.IcsGenerator

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text,
    TextBodyHelper,
    Urls
  }

  use Gettext, backend: TymeslotWeb.Gettext

  # A cancellation email communicates a negative state change.
  @intent :cancelled

  @spec render(
          :attendee | :organizer | :guest,
          String.t(),
          Tymeslot.Emails.EmailService.appointment_details()
        ) ::
          Swoosh.Email.t()
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
      #{Text.centered_text(dgettext("emails_booking", "Hi %{name} - our appointment has been cancelled. I'm sorry for the inconvenience.", name: appointment_details.attendee_name), padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{Text.centered_text(dgettext("emails_booking", "Would you like to schedule a new appointment?"), padding: "24px 0 10px 0")}
      #{Buttons.action_button(:confirmed, dgettext("emails_booking", "Schedule New Appointment"), booking_url(appointment_details), full_width: true)}

      #{Text.system_footer_note(dgettext("emails_booking", "This time slot is now available for booking again."))}
      #{Text.system_footer_note(dgettext("emails_booking", "If you have any questions, please don't hesitate to reach out."))}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "Cancelled"),
          stage_title: dgettext("emails_booking", "Meeting cancelled"),
          stage_subtitle:
            dgettext("emails_booking", "with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({appointment_details.attendee_name, attendee_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_booking", "Meeting Cancelled - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_attendee(appointment_details, locale))
      |> attachment(cancel_ics_attachment(appointment_details, locale))
    end)
  end

  def render(:guest, guest_email, appointment_details) do
    # Guests inherit the booker's locale, as their invitation does.
    locale = Map.get(appointment_details, :attendee_locale, "en")

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      guest_name = Map.get(appointment_details, :guest_name) || guest_email

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
      #{Text.centered_text(dgettext("emails_booking", "Hi %{guest} - the meeting with %{organizer} that %{booker} invited you to has been cancelled.", guest: guest_name, organizer: appointment_details.organizer_name, booker: appointment_details.attendee_name), padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(meeting_details, locale)}

      #{Text.system_footer_note(dgettext("emails_booking", "You don't need to do anything. If you added the meeting to your calendar, the attached file marks it as cancelled there."))}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "Cancelled"),
          stage_title: dgettext("emails_booking", "Meeting cancelled"),
          stage_subtitle:
            dgettext("emails_booking", "with %{name}", name: appointment_details.organizer_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)
      date_short = Formatting.format_date_short(appointment_details.date, locale)

      MjmlEmail.base_email()
      |> to({guest_name, guest_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_booking", "Meeting Cancelled - %{date} with %{name}",
            date: date_short,
            name: appointment_details.organizer_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_guest(appointment_details, guest_name, locale))
      |> attachment(cancel_ics_attachment(appointment_details, locale))
    end)
  end

  def render(:organizer, organizer_email, appointment_details) do
    Gettext.with_locale(TymeslotWeb.Gettext, organizer_locale(appointment_details), fn ->
      refund_notice = RefundNotice.build(appointment_details)

      mjml_content = """
      #{Text.centered_text(dgettext("emails_booking", "The appointment with %{name} has been cancelled.", name: appointment_details.attendee_name), padding: "8px 0 16px 0")}

      #{MeetingComponents.meeting_details_table(TemplateHelper.organizer_meeting_details(appointment_details), organizer_locale(appointment_details))}

      #{MeetingComponents.custom_answers_section(appointment_details)}

      #{RefundNotice.html(refund_notice)}

      #{Text.system_footer_note(dgettext("emails_booking", "The attendee has been notified of the cancellation."))}
      """

      organizer_details =
        TemplateHelper.build_organizer_details(appointment_details,
          intent: @intent,
          eyebrow: dgettext("emails_booking", "Cancelled"),
          stage_title: dgettext("emails_booking", "Meeting cancelled"),
          stage_subtitle:
            dgettext("emails_booking", "with %{name}", name: appointment_details.attendee_name)
        )

      html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

      MjmlEmail.base_email()
      |> to({appointment_details.organizer_name, organizer_email})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails_booking", "Meeting Cancelled - %{date} with %{name}",
            date:
              Formatting.format_date_short(
                appointment_details.date,
                organizer_locale(appointment_details)
              ),
            name: appointment_details.attendee_name
          )
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_organizer(appointment_details, refund_notice))
    end)
  end

  defp text_body_attendee(appointment_details, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)
    custom_answers = TextBodyHelper.format_custom_answers(appointment_details, locale)

    """
    #{dgettext("emails_booking", "Meeting Cancelled")}

    #{dgettext("emails_booking", "Hi %{name},", name: appointment_details.attendee_name)}

    #{dgettext("emails_booking", "We're writing to confirm that your appointment has been cancelled.")}

    #{dgettext("emails_booking", "CANCELLED APPOINTMENT DETAILS:")}
    #{dgettext("emails_booking", "Meeting with:")} #{appointment_details.organizer_name}
    #{meeting_details}#{custom_answers}

    #{dgettext("emails_booking", "This time slot is now available for booking again.")}

    #{dgettext("emails_booking", "Would you like to schedule a new appointment?")}
    #{dgettext("emails_booking", "Visit:")} #{booking_url(appointment_details)}

    #{dgettext("emails_booking", "If you have any questions, please don't hesitate to reach out.")}
    """
  end

  defp text_body_guest(appointment_details, guest_name, locale) do
    meeting_details = TextBodyHelper.format_meeting_details(appointment_details, locale)

    """
    #{dgettext("emails_booking", "Meeting Cancelled")}

    #{dgettext("emails_booking", "Hi %{guest},", guest: guest_name)}

    #{dgettext("emails_booking", "The meeting with %{organizer} that %{booker} invited you to has been cancelled.", organizer: appointment_details.organizer_name, booker: appointment_details.attendee_name)}

    #{dgettext("emails_booking", "CANCELLED APPOINTMENT DETAILS:")}
    #{meeting_details}

    #{dgettext("emails_booking", "You don't need to do anything. If you added the meeting to your calendar, the attached file marks it as cancelled there.")}
    """
  end

  # Detail maps built by hand rather than by `AppointmentBuilder` may carry no
  # booking URL; fall back to the app root so the CTA is never empty.
  defp booking_url(appointment_details) do
    Map.get(appointment_details, :booking_url) || Urls.get_app_url()
  end

  defp organizer_locale(appointment_details),
    do: RecipientLocale.organizer_locale(appointment_details)

  # Builds a `METHOD:PUBLISH` + `STATUS:CANCELLED` ICS attachment so the
  # attendee's calendar client shows the event as cancelled. We avoid iTIP
  # `METHOD:CANCEL` on the wire to keep recipient MTAs (Zimbra, Nextcloud,
  # iCloud) from auto-processing the attachment and firing extra notifications
  # — see issue #41. Sequence bumps the last-known value so the cancellation
  # supersedes any prior entry in the calendar.
  defp cancel_ics_attachment(appointment_details, locale) do
    current_sequence = Map.get(appointment_details, :ical_sequence) || 0

    IcsGenerator.generate_ics_cancel_attachment(
      appointment_details,
      current_sequence + 1,
      locale,
      "appointment-#{appointment_details.uid}.ics"
    )
  end

  defp text_body_organizer(appointment_details, refund_notice) do
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

    custom_answers =
      TextBodyHelper.format_custom_answers(
        appointment_details,
        organizer_locale(appointment_details)
      )

    """
    #{dgettext("emails_booking", "Meeting Cancelled")}

    #{dgettext("emails_booking", "The appointment with %{name} has been cancelled.", name: appointment_details.attendee_name)}

    #{dgettext("emails_booking", "CANCELLED APPOINTMENT DETAILS:")}
    #{meeting_details}#{attendee_info}#{custom_answers}#{RefundNotice.text(refund_notice)}

    #{dgettext("emails_booking", "The attendee has been notified of the cancellation.")}
    """
  end
end
