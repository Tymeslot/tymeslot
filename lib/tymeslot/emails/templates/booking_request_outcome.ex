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
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  use Gettext, backend: TymeslotWeb.Gettext

  @type variant :: :declined | :expired

  @spec render(variant(), Meeting.t()) :: Swoosh.Email.t()
  def render(variant, %Meeting{} = meeting) when variant in [:declined, :expired] do
    locale = meeting.attendee_locale || "en"

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)
      details = meeting_details(meeting, attendee_time)

      mjml_content = """
      #{Text.section_title(dgettext("emails", "Requested Time"))}
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{explanation(variant, meeting)}
      </mj-text>

      #{reason_block(variant, meeting)}

      #{Buttons.action_button(:confirmed, dgettext("emails", "Pick another time"), Urls.get_app_url(), full_width: true)}

      #{Text.system_footer_note(dgettext("emails", "This time slot is available for booking again."))}
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          headline(variant),
          preheader(variant, meeting),
          intent: :cancelled,
          eyebrow: eyebrow(variant),
          stage_title: headline(variant),
          stage_subtitle: preheader(variant, meeting)
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> subject(
        Sanitise.sanitize_for_header(
          subject_line(variant, meeting, Formatting.format_date_short(attendee_time, locale))
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for(variant, meeting, details, locale))
    end)
  end

  defp headline(:declined), do: dgettext("emails", "Booking Request Declined")
  defp headline(:expired), do: dgettext("emails", "Booking Request Expired")

  defp eyebrow(:declined), do: dgettext("emails", "Not confirmed")
  defp eyebrow(:expired), do: dgettext("emails", "No longer held")

  defp subject_line(:declined, meeting, date) do
    dgettext("emails", "Request declined: %{title} - %{date}", title: meeting.title, date: date)
  end

  defp subject_line(:expired, meeting, date) do
    dgettext("emails", "Request expired: %{title} - %{date}", title: meeting.title, date: date)
  end

  defp preheader(:declined, meeting) do
    dgettext("emails", "Hi %{name}, %{organizer} can't make this time.",
      name: meeting.attendee_name,
      organizer: meeting.organizer_name
    )
  end

  defp preheader(:expired, meeting) do
    dgettext("emails", "Hi %{name}, this request wasn't answered in time.",
      name: meeting.attendee_name
    )
  end

  defp explanation(:declined, meeting) do
    dgettext(
      "emails",
      "%{organizer} wasn't able to take this booking, so the time is no longer held for you.",
      organizer: meeting.organizer_name
    )
  end

  defp explanation(:expired, meeting) do
    dgettext(
      "emails",
      "%{organizer} didn't get to your request in time, so the time has been released. You are welcome to pick another slot.",
      organizer: meeting.organizer_name
    )
  end

  # A decline with a note reads as a person answering; without one it reads as
  # a machine. Where the host wrote nothing we say nothing rather than
  # inventing a reason on their behalf.
  defp reason_block(:declined, %Meeting{decline_reason: reason}) when is_binary(reason) do
    """
    <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="22px" padding="8px 0 0 0">
      #{dgettext("emails", "They added:")}
    </mj-text>
    <mj-text font-size="15px" color="#{Styles.ink_soft()}" line-height="22px" font-style="italic" padding="4px 0 0 16px">
      #{Sanitise.sanitize_for_email(reason)}
    </mj-text>
    """
  end

  defp reason_block(_variant, _meeting), do: ""

  defp meeting_details(meeting, attendee_time) do
    %{
      date: attendee_time,
      start_time: attendee_time,
      start_time_attendee_tz: attendee_time,
      duration: meeting.duration,
      location: meeting.location,
      location_type: BookingRequestLocation.type(meeting),
      meeting_type: meeting.meeting_type || dgettext("emails", "Meeting"),
      timezone: meeting.attendee_timezone || "UTC"
    }
  end

  defp text_body_for(variant, meeting, details, locale) do
    """
    #{headline(variant)}

    #{dgettext("emails", "Hi %{name},", name: meeting.attendee_name)}

    #{explanation(variant, meeting)}

    #{dgettext("emails", "REQUESTED TIME:")}
    #{dgettext("emails", "Date:")} #{Formatting.format_date_short(details.date, locale)}
    #{dgettext("emails", "Duration:")} #{Formatting.format_duration(details.duration, locale)}
    #{dgettext("emails", "Location:")} #{Formatting.format_location(details)}
    #{dgettext("emails", "Type:")} #{details.meeting_type}
    #{dgettext("emails", "Timezone:")} #{details.timezone}
    #{text_reason(variant, meeting)}
    #{dgettext("emails", "This time slot is available for booking again.")}

    #{dgettext("emails", "Pick another time:")} #{Urls.get_app_url()}
    """
  end

  defp text_reason(:declined, %Meeting{decline_reason: reason}) when is_binary(reason) do
    "\n" <> dgettext("emails", "They added:") <> "\n" <> reason <> "\n"
  end

  defp text_reason(_variant, _meeting), do: ""
end
