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

  alias Tymeslot.Emails.Shared.{
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text,
    TimezoneHelper
  }

  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Profiles

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  @spec render(Meeting.t(), String.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      host_tz = host_timezone(meeting)
      host_time = TimezoneHelper.convert_to_timezone(meeting.start_time, host_tz)
      details = meeting_details(meeting, host_time, host_tz)

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
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext(
            "emails_booking_requests",
            "Reschedule request expired, booking cancelled: %{name} - %{date}",
            name: meeting.attendee_name,
            date: Formatting.format_date_short(host_time, locale)
          )
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

  # Same resolution as `BookingApprovalRequest`: the host's profile timezone,
  # falling back to the platform default for an unregistered organiser.
  defp host_timezone(%Meeting{organizer_user_id: nil}), do: Profiles.get_default_timezone()

  defp host_timezone(%Meeting{organizer_user_id: user_id}),
    do: Profiles.get_user_timezone(user_id)

  defp meeting_details(meeting, host_time, host_tz) do
    %{
      date: host_time,
      start_time: host_time,
      duration: meeting.duration,
      location: meeting.location,
      location_type: BookingRequestLocation.type(meeting),
      meeting_type: meeting.meeting_type || dgettext("emails_booking_requests", "Meeting"),
      timezone: host_tz
    }
  end

  defp text_body_for(meeting, details, locale) do
    """
    #{dgettext("emails_booking_requests", "Reschedule Request Expired")}

    #{summary(meeting)}

    #{dgettext("emails_booking_requests", "From:")} #{meeting.attendee_name} <#{meeting.attendee_email}>

    #{dgettext("emails_booking_requests", "REQUESTED TIME:")}
    #{dgettext("emails_booking_requests", "Date:")} #{Formatting.format_date_short(details.date, locale)}
    #{dgettext("emails_booking_requests", "Duration:")} #{Formatting.format_duration(details.duration, locale)}
    #{dgettext("emails_booking_requests", "Location:")} #{Formatting.format_location(details)}
    #{dgettext("emails_booking_requests", "Type:")} #{details.meeting_type}
    #{dgettext("emails_booking_requests", "Timezone:")} #{details.timezone}

    #{explanation(meeting)}
    """
  end
end
