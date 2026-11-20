defmodule Tymeslot.Emails.Templates.RescheduleRequestUnanswered do
  @moduledoc """
  Tells the host that the attendee never picked a new time after the host
  asked them to, so the meeting has expired
  (`Tymeslot.Bookings.RescheduleRequestExpiry`).

  The host's own request voided the meeting's time, so without this email
  they would only notice a request that quietly stopped being answerable.
  On a group meeting it speaks of the participants still on it rather than
  one attendee.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.HostClock

  alias Tymeslot.Emails.Shared.{
    BookingRequestLocation,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TextBodyHelper
  }

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Utils.DateTimeUtils

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  @spec render(Meeting.t(), String.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      clock = HostClock.for_meeting(meeting, locale)
      host_time = DateTimeUtils.convert_to_timezone(meeting.start_time, clock.timezone)
      details = meeting_details(meeting, host_time, clock)

      mjml_content = """
      #{attendee_section(meeting)}

      #{Text.section_title(dgettext("emails_booking_requests", "Original Time"))}
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{Sanitise.sanitize_for_email(explanation(meeting))}
      </mj-text>
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          headline(),
          summary(meeting),
          intent: @intent,
          eyebrow: dgettext("emails_booking_requests", "Meeting expired"),
          stage_title: headline(),
          stage_subtitle: summary(meeting)
        )

      MjmlEmail.base_email()
      |> to({meeting.organizer_name, meeting.organizer_email})
      |> put_reply_to(meeting)
      |> subject(
        dgettext("emails_booking_requests", "No new time picked: %{title} - %{date}",
          title: meeting.title,
          date: Formatting.format_date_short(host_time, locale)
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for(meeting, details, locale))
    end)
  end

  defp headline, do: dgettext("emails_booking_requests", "No New Time Picked")

  defp attendee_section(meeting) do
    if Meeting.group?(meeting),
      do: "",
      else:
        MeetingComponents.attendee_info_section(@intent, %{
          name: meeting.attendee_name,
          email: meeting.attendee_email
        })
  end

  # A group meeting has no one attendee to reply to.
  defp put_reply_to(email, meeting) do
    if Meeting.group?(meeting),
      do: email,
      else: MjmlEmail.put_reply_to(email, meeting.attendee_name, meeting.attendee_email)
  end

  defp summary(meeting) do
    if Meeting.group?(meeting) do
      dgettext(
        "emails_booking_requests",
        "Nobody picked a new time for %{title}, so it has expired.",
        title: meeting.title
      )
    else
      dgettext(
        "emails_booking_requests",
        "%{name} didn't pick a new time, so your meeting has expired.",
        name: meeting.attendee_name
      )
    end
  end

  defp explanation(meeting) do
    if Meeting.group?(meeting) do
      dgettext(
        "emails_booking_requests",
        "You asked for this meeting to be moved, and the request lapsed before anyone still on it picked a new time. Its original time had already been given up, so the meeting has expired. The participants have been told and can book again from your booking page."
      )
    else
      dgettext(
        "emails_booking_requests",
        "You asked %{name} to pick a new time for this meeting, and the request lapsed before they did. Its original time had already been given up, so the meeting has expired. %{name} has been told and can book again from your booking page.",
        name: meeting.attendee_name
      )
    end
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
    #{headline()}

    #{summary(meeting)}

    #{dgettext("emails_booking_requests", "ORIGINAL TIME:")}
    #{TextBodyHelper.format_meeting_details(details, locale)}

    #{explanation(meeting)}
    """
  end
end
