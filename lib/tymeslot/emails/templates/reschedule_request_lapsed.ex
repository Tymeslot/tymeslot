defmodule Tymeslot.Emails.Templates.RescheduleRequestLapsed do
  @moduledoc """
  Tells an attendee that the host's request to pick a new time has lapsed
  unanswered (`Tymeslot.Bookings.RescheduleRequestExpiry`), so nothing is
  booked any more, and points them at the host's booking page to book again.

  Rendered from the meeting as its recipient sees it
  (`Tymeslot.Meetings.Recipient.as_seen_by/2`), so a group participant gets
  their own name, language and calendar identity. It carries a cancellation
  `.ics` for that identity: the request email told the attendee their time
  was off but sent nothing to their calendar, so the entry the confirmation
  put there would otherwise stay.
  """

  import Swoosh.Email

  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.ContentTranslations.AttendeeTexts
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    BookingRequestLocation,
    Buttons,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TextBodyHelper,
    TimezoneHelper
  }

  alias Tymeslot.Integrations.Calendar.IcsGenerator
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  @spec render(Meeting.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting) do
    locale = RecipientLocale.attendee_locale(meeting)
    booking_page_url = MeetingLinks.booking_page_url(meeting)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      # The stored title and texts are in the organiser's language; the
      # attendee reads them in theirs.
      meeting = AttendeeTexts.attendee_view(meeting, locale)
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)

      details =
        Formatting.without_location_note(%{
          date: attendee_time,
          start_time: attendee_time,
          start_time_attendee_tz: attendee_time,
          duration: meeting.duration,
          location: meeting.location,
          location_type: BookingRequestLocation.type(meeting),
          meeting_type: meeting.meeting_type || dgettext("emails_booking_requests", "Meeting")
        })

      mjml_content = """
      #{Text.section_title(dgettext("emails_booking_requests", "Original Time"))}
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{Sanitise.sanitize_for_email(explanation(meeting))}
      </mj-text>

      #{Buttons.action_button(:confirmed, book_again_label(), booking_page_url, full_width: true)}
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          headline(),
          preheader(meeting),
          intent: @intent,
          eyebrow: dgettext("emails_booking_requests", "No longer held"),
          stage_title: headline(),
          stage_subtitle: preheader(meeting)
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> MjmlEmail.put_reply_to(meeting.organizer_name, meeting.organizer_email)
      |> subject(
        dgettext("emails_booking_requests", "Reschedule request lapsed: %{title} - %{date}",
          title: meeting.title,
          date: Formatting.format_date_short(attendee_time, locale)
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for(meeting, details, booking_page_url, locale))
      |> attachment(cancellation_ics(meeting, locale))
    end)
  end

  defp headline, do: dgettext("emails_booking_requests", "Reschedule Request Lapsed")

  defp book_again_label, do: dgettext("emails_booking_requests", "Book a new time")

  defp preheader(meeting) do
    dgettext(
      "emails_booking_requests",
      "Hi %{name}, the request to pick a new time has lapsed.",
      name: meeting.attendee_name
    )
  end

  defp explanation(meeting) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} asked you to pick a new time for this meeting, and that request has now lapsed. The original time had already been cancelled, so nothing is booked. If you'd still like to meet, you can book a new time from the booking page.",
      organizer: meeting.organizer_name
    )
  end

  defp text_body_for(meeting, details, booking_page_url, locale) do
    """
    #{headline()}

    #{dgettext("emails_booking_requests", "Hi %{name},", name: meeting.attendee_name)}

    #{explanation(meeting)}

    #{dgettext("emails_booking_requests", "ORIGINAL TIME:")}
    #{TextBodyHelper.format_meeting_details(details, locale)}

    #{book_again_label()}: #{booking_page_url}
    """
  end

  # `METHOD:PUBLISH` + `STATUS:CANCELLED` for the calendar identity the
  # confirmation used, at the next sequence, as `BookingRequestOutcome` sends.
  defp cancellation_ics(meeting, locale) do
    IcsGenerator.generate_ics_cancel_attachment(
      # The `.ics` UID is the calendar identity, never the booking's
      # capability-bearing `uid`.
      meeting |> Map.from_struct() |> Map.put(:uid, meeting.calendar_uid),
      meeting.ical_sequence + 1,
      locale,
      "appointment-#{meeting.calendar_uid}.ics"
    )
  end
end
