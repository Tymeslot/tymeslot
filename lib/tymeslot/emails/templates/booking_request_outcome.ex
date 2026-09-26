defmodule Tymeslot.Emails.Templates.BookingRequestOutcome do
  @moduledoc """
  Tells an invitee their booking request will not happen.

  Two variants, and the distinction is not pedantry:

    * `:declined` — the host read the request and said no. If they gave a
      reason it is quoted back, because a declined request without one reads
      as a system failure rather than a decision.
    * `:expired` — nobody answered before the deadline. The host did not
      refuse, and saying they did would be a lie about a real person. The
      wording keeps the door open and points at rebooking.

  Both close the loop the acknowledgement opened. An invitee told their time
  was held must be told when it stops being held, and the silence that would
  otherwise follow an unanswered request is the single worst outcome this
  feature can produce.

  A booking that was confirmed before and re-entered the gate through a
  reschedule (it has a `first_announced_at`) loses more than the requested
  time: releasing it cancels the booking itself. For it the email says so,
  and carries a cancellation `.ics` for the booking's UID, so the entry the
  original confirmation put in the invitee's calendar does not linger.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TimezoneHelper,
    Urls
  }

  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  use Gettext, backend: TymeslotWeb.Gettext

  @type variant :: :declined | :expired

  @spec render(variant(), Meeting.t()) :: Swoosh.Email.t()
  def render(variant, %Meeting{} = meeting) when variant in [:declined, :expired] do
    locale = meeting.attendee_locale || "en"

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      kind = if rescheduled?(meeting), do: :reschedule, else: :booking
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)
      details = meeting_details(meeting, attendee_time)

      mjml_content = """
      #{Text.section_title(requested_time_title(kind))}
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{Sanitise.sanitize_for_email(explanation({variant, kind}, meeting))}
      </mj-text>

      #{reason_block({variant, kind}, meeting)}

      #{Buttons.action_button(:confirmed, dgettext("emails_booking_requests", "Pick another time"), Urls.get_app_url(), full_width: true)}

      #{Text.system_footer_note(dgettext("emails_booking_requests", "This time slot is available for booking again."))}
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          headline({variant, kind}),
          preheader({variant, kind}, meeting),
          intent: :cancelled,
          eyebrow: eyebrow({variant, kind}),
          stage_title: headline({variant, kind}),
          stage_subtitle: preheader({variant, kind}, meeting)
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> subject(
        Sanitise.sanitize_for_header(
          subject_line(
            {variant, kind},
            meeting,
            Formatting.format_date_short(attendee_time, locale)
          )
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for({variant, kind}, meeting, details, locale))
      |> maybe_cancel_calendar_entry(kind, meeting, locale)
    end)
  end

  # Confirmed once already: the request was to move a booking, and releasing
  # it cancelled that booking.
  defp rescheduled?(%Meeting{first_announced_at: %DateTime{}}), do: true
  defp rescheduled?(_meeting), do: false

  defp requested_time_title(:booking), do: dgettext("emails_booking_requests", "Requested Time")

  defp requested_time_title(:reschedule),
    do: dgettext("emails_booking_requests", "Requested New Time")

  defp headline({:declined, :booking}),
    do: dgettext("emails_booking_requests", "Booking Request Declined")

  defp headline({:expired, :booking}),
    do: dgettext("emails_booking_requests", "Booking Request Expired")

  defp headline({:declined, :reschedule}),
    do: dgettext("emails_booking_requests", "Reschedule Declined")

  defp headline({:expired, :reschedule}),
    do: dgettext("emails_booking_requests", "Reschedule Request Expired")

  defp eyebrow({:declined, :booking}), do: dgettext("emails_booking_requests", "Not confirmed")
  defp eyebrow({:expired, :booking}), do: dgettext("emails_booking_requests", "No longer held")

  defp eyebrow({_variant, :reschedule}),
    do: dgettext("emails_booking_requests", "Booking cancelled")

  defp subject_line({:declined, :booking}, meeting, date) do
    dgettext("emails_booking_requests", "Request declined: %{title} - %{date}",
      title: meeting.title,
      date: date
    )
  end

  defp subject_line({:expired, :booking}, meeting, date) do
    dgettext("emails_booking_requests", "Request expired: %{title} - %{date}",
      title: meeting.title,
      date: date
    )
  end

  defp subject_line({:declined, :reschedule}, meeting, date) do
    dgettext(
      "emails_booking_requests",
      "Reschedule declined, booking cancelled: %{title} - %{date}",
      title: meeting.title,
      date: date
    )
  end

  defp subject_line({:expired, :reschedule}, meeting, date) do
    dgettext(
      "emails_booking_requests",
      "Reschedule request expired, booking cancelled: %{title} - %{date}",
      title: meeting.title,
      date: date
    )
  end

  defp preheader({:declined, :reschedule}, meeting) do
    dgettext("emails_booking_requests", "Hi %{name}, %{organizer} can't make the new time.",
      name: meeting.attendee_name,
      organizer: meeting.organizer_name
    )
  end

  defp preheader({:expired, :reschedule}, meeting) do
    dgettext(
      "emails_booking_requests",
      "Hi %{name}, your reschedule request wasn't answered in time.",
      name: meeting.attendee_name
    )
  end

  defp preheader({:declined, :booking}, meeting) do
    dgettext("emails_booking_requests", "Hi %{name}, %{organizer} can't make this time.",
      name: meeting.attendee_name,
      organizer: meeting.organizer_name
    )
  end

  defp preheader({:expired, :booking}, meeting) do
    dgettext("emails_booking_requests", "Hi %{name}, this request wasn't answered in time.",
      name: meeting.attendee_name
    )
  end

  defp explanation({:declined, :reschedule}, meeting) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} wasn't able to accept the new time. Your previous time had already been given up for it, so your booking has been cancelled. The attached calendar file removes it from your calendar.",
      organizer: meeting.organizer_name
    )
  end

  defp explanation({:expired, :reschedule}, meeting) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} didn't get to your reschedule request in time. Your previous time had already been given up for it, so your booking has been cancelled. The attached calendar file removes it from your calendar.",
      organizer: meeting.organizer_name
    )
  end

  defp explanation({:declined, :booking}, meeting) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} wasn't able to take this booking, so the time is no longer held for you.",
      organizer: meeting.organizer_name
    )
  end

  defp explanation({:expired, :booking}, meeting) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} didn't get to your request in time, so the time has been released. You are welcome to pick another slot.",
      organizer: meeting.organizer_name
    )
  end

  # A decline with a note reads as a person answering; without one it reads as
  # a machine. Where the host wrote nothing we say nothing rather than
  # inventing a reason on their behalf. `is_binary(reason)` alone accepts
  # `""`, which would print the "They added:" label with nothing under it, so
  # the empty string is excluded here rather than relied upon to have already
  # been normalised to `nil` upstream.
  defp reason_block({:declined, _kind}, %Meeting{decline_reason: reason})
       when is_binary(reason) and reason != "" do
    """
    <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="22px" padding="8px 0 0 0">
      #{dgettext("emails_booking_requests", "They added:")}
    </mj-text>
    <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="22px" font-style="italic" padding="4px 0 0 16px">
      #{reason |> Sanitise.sanitize_for_email() |> String.replace("\n", "<br/>")}
    </mj-text>
    """
  end

  defp reason_block(_outcome, _meeting), do: ""

  defp meeting_details(meeting, attendee_time) do
    %{
      date: attendee_time,
      start_time: attendee_time,
      start_time_attendee_tz: attendee_time,
      duration: meeting.duration,
      location: meeting.location,
      location_type: BookingRequestLocation.type(meeting),
      meeting_type: meeting.meeting_type || dgettext("emails_booking_requests", "Meeting"),
      timezone: meeting.attendee_timezone || "UTC"
    }
  end

  defp text_body_for({_variant, _kind} = outcome, meeting, details, locale) do
    """
    #{headline(outcome)}

    #{dgettext("emails_booking_requests", "Hi %{name},", name: meeting.attendee_name)}

    #{explanation(outcome, meeting)}

    #{dgettext("emails_booking_requests", "REQUESTED TIME:")}
    #{dgettext("emails_booking_requests", "Date:")} #{Formatting.format_date_short(details.date, locale)}
    #{dgettext("emails_booking_requests", "Duration:")} #{Formatting.format_duration(details.duration, locale)}
    #{dgettext("emails_booking_requests", "Location:")} #{Formatting.format_location(details)}
    #{dgettext("emails_booking_requests", "Type:")} #{details.meeting_type}
    #{dgettext("emails_booking_requests", "Timezone:")} #{details.timezone}
    #{text_reason(outcome, meeting)}
    #{dgettext("emails_booking_requests", "This time slot is available for booking again.")}

    #{dgettext("emails_booking_requests", "Pick another time:")} #{Urls.get_app_url()}
    """
  end

  defp text_reason({:declined, _kind}, %Meeting{decline_reason: reason})
       when is_binary(reason) and reason != "" do
    "\n" <> dgettext("emails_booking_requests", "They added:") <> "\n" <> reason <> "\n"
  end

  defp text_reason(_outcome, _meeting), do: ""

  # The original confirmation put this booking in the invitee's calendar under
  # its UID. `METHOD:PUBLISH` + `STATUS:CANCELLED`, as the ordinary
  # cancellation email sends (see `AppointmentCancellation`), with the next
  # sequence so the client treats it as newer than what it has on file.
  defp maybe_cancel_calendar_entry(email, :reschedule, meeting, locale) do
    attachment(
      email,
      IcsGenerator.generate_ics_cancel_attachment(
        Map.from_struct(meeting),
        meeting.ical_sequence + 1,
        locale,
        "appointment-#{meeting.uid}.ics"
      )
    )
  end

  defp maybe_cancel_calendar_entry(email, :booking, _meeting, _locale), do: email
end
