defmodule Tymeslot.Emails.Templates.BookingRequestReceived do
  @moduledoc """
  Tells an invitee their booking request has arrived and is not yet confirmed.

  This is the first of two emails on a meeting type requiring the host's
  approval; the second is the ordinary `AppointmentConfirmation`, sent once
  they say yes. The split is the whole point of the feature, so the wording
  here has to be unambiguous: the time is held, nobody has agreed to it yet,
  and here is when they will know.

  Deliberately carries **no `.ics` attachment**. A calendar file is a promise
  the host has not made, and an invitee whose calendar already shows the
  meeting will not read the email that follows.
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

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  use Gettext, backend: TymeslotWeb.Gettext

  # Amber rather than the confirmed brand colour: the band is the first thing
  # read, and it should not say "done".
  @intent :alert

  @spec render(Meeting.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting) do
    locale = meeting.attendee_locale || "en"

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)
      details = meeting_details(meeting, attendee_time)

      mjml_content = """
      #{Text.section_title(dgettext("emails", "Requested Time"))}
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{waiting_sentence(meeting, locale)}
      </mj-text>

      <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="8px 0 0 0">
        #{dgettext("emails", "This time is held for you in the meantime, so nobody else can take it. You'll get a confirmation with the calendar invite as soon as %{organizer} accepts.", organizer: meeting.organizer_name)}
      </mj-text>

      #{cancel_line(meeting)}
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          dgettext("emails", "Booking Request Received"),
          dgettext(
            "emails",
            "Hi %{name}, we've passed your request to %{organizer}. It isn't confirmed yet.",
            name: meeting.attendee_name,
            organizer: meeting.organizer_name
          ),
          intent: @intent,
          eyebrow: dgettext("emails", "Awaiting confirmation"),
          stage_title: dgettext("emails", "Request received"),
          stage_subtitle:
            dgettext(
              "emails",
              "Hi %{name}, %{organizer} confirms each booking personally, so this isn't final yet.",
              name: meeting.attendee_name,
              organizer: meeting.organizer_name
            )
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> subject(
        Sanitise.sanitize_for_header(
          dgettext("emails", "Request received: %{title} - %{date}",
            title: meeting.title,
            date: Formatting.format_date_short(attendee_time, locale)
          )
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for(meeting, details, locale))
    end)
  end

  defp meeting_details(meeting, attendee_time) do
    %{
      date: attendee_time,
      start_time: attendee_time,
      start_time_attendee_tz: attendee_time,
      duration: meeting.duration,
      location: meeting.location,
      location_type: location_type(meeting),
      meeting_type: meeting.meeting_type || dgettext("emails", "Meeting"),
      timezone: meeting.attendee_timezone || "UTC"
    }
  end

  defp location_type(%Meeting{meeting_url: url}) when is_binary(url), do: :video
  defp location_type(%Meeting{location: "Phone Call"}), do: :phone
  defp location_type(%Meeting{location: "In Person"}), do: :in_person
  defp location_type(_meeting), do: :custom

  # Naming the deadline is what makes the wait tolerable. Where the request
  # has no deadline recorded we say nothing rather than inventing one.
  defp waiting_sentence(%Meeting{approval_deadline_at: nil} = meeting, _locale) do
    dgettext("emails", "%{organizer} will review your request and get back to you shortly.",
      organizer: meeting.organizer_name
    )
  end

  defp waiting_sentence(%Meeting{} = meeting, locale) do
    deadline =
      meeting.approval_deadline_at
      |> TimezoneHelper.convert_to_timezone(meeting.attendee_timezone || "UTC")
      |> Formatting.format_datetime(locale)

    dgettext("emails", "%{organizer} will reply by %{deadline} at the latest.",
      organizer: meeting.organizer_name,
      deadline: deadline
    )
  end

  defp cancel_line(%Meeting{cancel_url: nil}), do: ""

  defp cancel_line(%Meeting{cancel_url: url}) do
    """
    <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="16px 0 0 0">
      #{dgettext("emails", "Changed your mind? You can <a href=\"%{url}\" style=\"color:%{colour}\">withdraw your request</a> at any time.", url: url, colour: Styles.component_color(:link))}
    </mj-text>
    """
  end

  defp text_body_for(meeting, details, locale) do
    """
    #{dgettext("emails", "Booking Request Received")}

    #{dgettext("emails", "Hi %{name},", name: meeting.attendee_name)}

    #{dgettext("emails", "%{organizer} confirms each booking personally, so this isn't final yet.", organizer: meeting.organizer_name)}

    #{dgettext("emails", "REQUESTED TIME:")}
    #{dgettext("emails", "Date:")} #{Formatting.format_date_short(details.date, locale)}
    #{dgettext("emails", "Duration:")} #{Formatting.format_duration(details.duration, locale)}
    #{dgettext("emails", "Location:")} #{Formatting.format_location(details)}
    #{dgettext("emails", "Type:")} #{details.meeting_type}
    #{dgettext("emails", "Timezone:")} #{details.timezone}

    #{waiting_sentence(meeting, locale)}

    #{dgettext("emails", "This time is held for you in the meantime, so nobody else can take it. You'll get a confirmation with the calendar invite as soon as %{organizer} accepts.", organizer: meeting.organizer_name)}
    #{if meeting.cancel_url, do: "\n" <> dgettext("emails", "Withdraw your request:") <> "\n" <> meeting.cancel_url, else: ""}
    """
  end
end
