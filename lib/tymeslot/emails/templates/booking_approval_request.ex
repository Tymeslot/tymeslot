defmodule Tymeslot.Emails.Templates.BookingApprovalRequest do
  @moduledoc """
  Asks the host to approve or decline a booking request.

  Carries everything needed to decide without opening the dashboard: who is
  asking, what they said, their answers to any custom questions, the time they
  want, and the deadline after which the request lapses on its own.

  Both buttons point at the same review page. Neither acts on being followed —
  mail security scanners fetch every link in an inbound message, and a URL
  that approved on GET would fill the host's calendar with meetings they never
  saw. See `Tymeslot.Meetings.ApprovalToken`.

  Doubles as the nudge sent partway through the window: same body, different
  framing, chosen with the `:nudge` variant.
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
    TextBodyHelper,
    TimezoneHelper
  }

  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Profiles

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :alert

  @typedoc "First ask, or the reminder partway through the window."
  @type variant :: :request | :nudge

  @spec render(variant(), Meeting.t(), map(), String.t()) :: Swoosh.Email.t()
  def render(variant, %Meeting{} = meeting, urls, locale) when variant in [:request, :nudge] do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      host_tz = host_timezone(meeting)
      host_time = TimezoneHelper.convert_to_timezone(meeting.start_time, host_tz)
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)
      details = meeting_details(meeting, host_time, host_tz)
      deadline_text = deadline_sentence(meeting, host_tz, locale)

      mjml_content = """
      #{MeetingComponents.attendee_info_section(@intent, %{name: meeting.attendee_name, email: meeting.attendee_email})}

      #{MeetingComponents.attendee_message_box(@intent, meeting.attendee_message)}

      #{Text.section_title(dgettext("emails", "Requested Time"))}
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="6px 0 0 0">
        #{Sanitise.sanitize_for_email(attendee_time_sentence(meeting, attendee_time, locale))}
      </mj-text>

      #{MeetingComponents.custom_answers_section(meeting)}

      <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="8px 0 16px 0">
        #{Sanitise.sanitize_for_email(deadline_text)}
      </mj-text>

      #{Buttons.action_button(:confirmed, dgettext("emails", "Approve"), urls.approve_url, full_width: true, size: :large)}
      #{Buttons.action_button(:cancelled, dgettext("emails", "Decline"), urls.decline_url, full_width: true)}

      <mj-text font-size="13px" color="#{Styles.ink_muted()}" line-height="19px" padding="16px 0 0 0">
        #{dgettext("emails", "Both buttons open the request for you to confirm. Nothing is decided until you choose there.")}
      </mj-text>
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          title(variant),
          preview(variant, meeting),
          intent: @intent,
          eyebrow: eyebrow(variant),
          stage_title: title(variant),
          stage_subtitle:
            dgettext("emails", "%{name} would like to book %{type} with you.",
              name: meeting.attendee_name,
              type: meeting.meeting_type || dgettext("emails", "a meeting")
            )
        )

      MjmlEmail.base_email()
      |> to({meeting.organizer_name, meeting.organizer_email})
      |> subject(
        Sanitise.sanitize_for_header(
          subject_line(variant, meeting, Formatting.format_date_short(host_time, locale))
        )
      )
      |> html_body(html_body)
      |> text_body(
        text_body_for(variant, meeting, details, attendee_time, deadline_text, urls, locale)
      )
    end)
  end

  defp eyebrow(:request), do: dgettext("emails", "Needs your answer")
  defp eyebrow(:nudge), do: dgettext("emails", "Still waiting")

  defp title(:request), do: dgettext("emails", "New booking request")
  defp title(:nudge), do: dgettext("emails", "Booking request still waiting")

  defp preview(:request, meeting) do
    dgettext("emails", "%{name} is waiting on your answer.", name: meeting.attendee_name)
  end

  defp preview(:nudge, meeting) do
    dgettext("emails", "%{name} is still waiting on your answer.", name: meeting.attendee_name)
  end

  defp subject_line(:request, meeting, date) do
    dgettext("emails", "Booking request: %{name} - %{date}",
      name: meeting.attendee_name,
      date: date
    )
  end

  defp subject_line(:nudge, meeting, date) do
    dgettext("emails", "Reminder - booking request: %{name} - %{date}",
      name: meeting.attendee_name,
      date: date
    )
  end

  # The host reads the time in their own zone, resolved from their profile
  # (falling back to the platform default for an unregistered organiser) —
  # the same resolution `CalendarEmails.resolve_owner_timezone/1` uses for
  # every other host-addressed email. The invitee's own zone is rendered
  # separately in `attendee_time_sentence/3`, so both are visible without
  # arithmetic.
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
      meeting_type: meeting.meeting_type || dgettext("emails", "Meeting"),
      timezone: host_tz
    }
  end

  defp attendee_time_sentence(meeting, attendee_time, locale) do
    formatted = Formatting.format_datetime(attendee_time, locale)
    zone = meeting.attendee_timezone || "UTC"
    time_with_zone = if zone != "UTC", do: "#{formatted} (#{zone})", else: formatted

    dgettext("emails", "For %{name}, that's %{time}.",
      name: meeting.attendee_name,
      time: time_with_zone
    )
  end

  defp deadline_sentence(%Meeting{approval_deadline_at: nil} = meeting, _host_tz, _locale) do
    dgettext("emails", "The slot stays held for %{name} until you answer.",
      name: meeting.attendee_name
    )
  end

  defp deadline_sentence(%Meeting{} = meeting, host_tz, locale) do
    deadline =
      meeting.approval_deadline_at
      |> TimezoneHelper.convert_to_timezone(host_tz)
      |> Formatting.format_datetime(locale)

    dgettext(
      "emails",
      "The slot is held until you answer. If you haven't replied by %{deadline}, the request lapses and %{name} is told the time is free again.",
      deadline: deadline,
      name: meeting.attendee_name
    )
  end

  defp text_body_for(variant, meeting, details, attendee_time, deadline_text, urls, locale) do
    """
    #{title(variant)}

    #{dgettext("emails", "%{name} would like to book %{type} with you.", name: meeting.attendee_name, type: meeting.meeting_type || dgettext("emails", "a meeting"))}

    #{dgettext("emails", "From:")} #{meeting.attendee_name} <#{meeting.attendee_email}>
    #{if meeting.attendee_message, do: dgettext("emails", "Message:") <> " " <> meeting.attendee_message, else: ""}

    #{dgettext("emails", "REQUESTED TIME:")}
    #{dgettext("emails", "Date:")} #{Formatting.format_date_short(details.date, locale)}
    #{dgettext("emails", "Time:")} #{Formatting.format_time(details.start_time, locale)}
    #{dgettext("emails", "Duration:")} #{Formatting.format_duration(details.duration, locale)}
    #{dgettext("emails", "Location:")} #{Formatting.format_location(details)}
    #{dgettext("emails", "Timezone:")} #{details.timezone}

    #{attendee_time_sentence(meeting, attendee_time, locale)}
    #{TextBodyHelper.format_custom_answers(meeting, locale)}
    #{deadline_text}

    #{dgettext("emails", "Approve:")}
    #{urls.approve_url}

    #{dgettext("emails", "Decline:")}
    #{urls.decline_url}

    #{dgettext("emails", "Both links open the request for you to confirm. Nothing is decided until you choose there.")}
    """
  end
end
