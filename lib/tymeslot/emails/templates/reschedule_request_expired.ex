defmodule Tymeslot.Emails.Templates.RescheduleRequestExpired do
  @moduledoc """
  Tells the host that a confirmed booking was cancelled because the invitee's
  request to move it lapsed.

  A reschedule on a meeting type requiring approval sends a confirmed booking
  back into the approval gate, and the previous time is given up for the new
  one. If nobody answers before the deadline, releasing the request cancels
  the booking itself. The invitee is told by `BookingRequestOutcome`; without
  this email the host would only notice a meeting missing from their
  calendar, since nobody declined anything.

  Only for a booking that was confirmed before (`first_announced_at`). A
  first-time request that lapses cost the host no meeting they had.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.HostClock

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  alias Tymeslot.Utils.DateTimeUtils

  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  @spec render(Meeting.t(), String.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      clock = HostClock.for_meeting(meeting, locale)
      host_time = DateTimeUtils.convert_to_timezone(meeting.start_time, clock.timezone)
      details = meeting_details(meeting, host_time, clock)

      mjml_content = """
      #{MeetingComponents.attendee_info_section(@intent, %{name: meeting.attendee_name, email: meeting.attendee_email})}

      #{Text.section_title(dgettext("emails_booking_requests", "Requested New Time"))}
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{Sanitise.sanitize_for_email(explanation(meeting))}
      </mj-text>
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          dgettext("emails_booking_requests", "Reschedule Request Expired"),
          summary(meeting),
          intent: @intent,
          eyebrow: dgettext("emails_booking_requests", "Booking cancelled"),
          stage_title: dgettext("emails_booking_requests", "Reschedule Request Expired"),
          stage_subtitle: summary(meeting)
        )

      MjmlEmail.base_email()
      |> to({meeting.organizer_name, meeting.organizer_email})
      |> MjmlEmail.put_reply_to(meeting.attendee_name, meeting.attendee_email)
      |> subject(
        dgettext(
          "emails_booking_requests",
          "Reschedule request expired, booking cancelled: %{name} - %{date}",
          name: meeting.attendee_name,
          date: Formatting.format_date_short(host_time, locale)
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for(meeting, details, locale))
    end)
  end

  defp summary(meeting) do
    dgettext("emails_booking_requests", "Your booking with %{name} has been cancelled.",
      name: meeting.attendee_name
    )
  end

  defp explanation(meeting) do
    dgettext(
      "emails_booking_requests",
      "%{name} asked to move their confirmed booking to this time, and the request wasn't answered before its deadline. The previous time had already been given up for it, so the booking has been cancelled. %{name} has been told and can book a new time.",
      name: meeting.attendee_name
    )
  end

  # The host reads the time in their own zone and on their own clock.
  defp meeting_details(meeting, host_time, clock) do
    %{
      date: host_time,
      start_time: host_time,
      duration: meeting.duration,
      location: meeting.location,
      location_type: BookingRequestLocation.type(meeting),
      meeting_type: meeting.meeting_type || dgettext("emails_booking_requests", "Meeting"),
      time_format: clock.time_format,
      audience: :host
    }
  end

  defp text_body_for(meeting, details, locale) do
    """
    #{dgettext("emails_booking_requests", "Reschedule Request Expired")}

    #{summary(meeting)}

    #{dgettext("emails_booking_requests", "From:")} #{meeting.attendee_name} <#{meeting.attendee_email}>

    #{dgettext("emails_booking_requests", "REQUESTED TIME:")}
    #{TextBodyHelper.format_meeting_details(details, locale)}

    #{explanation(meeting)}
    """
  end
end
