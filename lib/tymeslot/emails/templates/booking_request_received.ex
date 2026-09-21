defmodule Tymeslot.Emails.Templates.BookingRequestReceived do
  @moduledoc """
  Tells an invitee their booking request has arrived and is not yet confirmed.

  This is the first of two emails on a meeting type requiring the host's
  approval; the second is the ordinary `AppointmentConfirmation`, sent once
  they say yes. The split is the whole point of the feature, so the wording
  here has to be unambiguous: the time is held, nobody has agreed to it yet,
  and here is when they will know.

  A booking that was confirmed before and is back in the gate because the
  invitee moved it (it has a `first_announced_at`) gets the reschedule
  wording instead, with `opts[:previous_start_time]` shown when the caller
  knows it.

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

  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  use Gettext, backend: TymeslotWeb.Gettext

  # Amber rather than the confirmed brand colour: the band is the first thing
  # read, and it should not say "done".
  @intent :alert

  @spec render(Meeting.t(), keyword()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, opts \\ []) do
    locale = meeting.attendee_locale || "en"

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      kind = if rescheduled?(meeting), do: :reschedule, else: :booking
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)
      details = meeting_details(meeting, attendee_time)
      previous = previous_time_text(meeting, opts, locale)

      mjml_content = """
      #{Text.section_title(requested_time_title(kind))}
      #{MeetingComponents.meeting_details_table(details, locale)}
      #{if previous, do: ~s(<mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="6px 0 0 0">#{Sanitise.sanitize_for_email(previous)}</mj-text>), else: ""}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0">
        #{Sanitise.sanitize_for_email(waiting_sentence(meeting, locale))}
      </mj-text>

      <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="8px 0 0 0">
        #{Sanitise.sanitize_for_email(held_sentence(meeting, kind))}
      </mj-text>

      #{cancel_line(meeting)}
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          heading(kind),
          dgettext(
            "emails",
            "Hi %{name}, we've passed your request to %{organizer}. It isn't confirmed yet.",
            name: meeting.attendee_name,
            organizer: meeting.organizer_name
          ),
          intent: @intent,
          eyebrow: dgettext("emails", "Awaiting confirmation"),
          stage_title: stage_title(kind),
          stage_subtitle: personal_sentence(meeting, kind)
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> subject(
        Sanitise.sanitize_for_header(
          subject_line(kind, meeting, Formatting.format_date_short(attendee_time, locale))
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for({meeting, kind}, details, previous, locale))
    end)
  end

  # Confirmed once already: the invitee is moving a meeting, not booking one.
  defp rescheduled?(%Meeting{first_announced_at: %DateTime{}}), do: true
  defp rescheduled?(_meeting), do: false

  defp heading(:booking), do: dgettext("emails", "Booking Request Received")
  defp heading(:reschedule), do: dgettext("emails", "Reschedule Request Received")

  defp stage_title(:booking), do: dgettext("emails", "Request received")
  defp stage_title(:reschedule), do: dgettext("emails", "Reschedule requested")

  defp requested_time_title(:booking), do: dgettext("emails", "Requested Time")
  defp requested_time_title(:reschedule), do: dgettext("emails", "Requested New Time")

  defp personal_sentence(meeting, :booking) do
    dgettext(
      "emails",
      "Hi %{name}, %{organizer} confirms each booking personally, so this isn't final yet.",
      name: meeting.attendee_name,
      organizer: meeting.organizer_name
    )
  end

  defp personal_sentence(meeting, :reschedule) do
    dgettext(
      "emails",
      "Hi %{name}, %{organizer} confirms each change personally, so the new time isn't final yet.",
      name: meeting.attendee_name,
      organizer: meeting.organizer_name
    )
  end

  defp text_intro(meeting, :booking) do
    dgettext("emails", "%{organizer} confirms each booking personally, so this isn't final yet.",
      organizer: meeting.organizer_name
    )
  end

  defp text_intro(meeting, :reschedule) do
    dgettext(
      "emails",
      "%{organizer} confirms each change personally, so the new time isn't final yet.",
      organizer: meeting.organizer_name
    )
  end

  defp held_sentence(meeting, :booking) do
    dgettext(
      "emails",
      "This time is held for you in the meantime, so nobody else can take it. You'll get a confirmation with the calendar invite as soon as %{organizer} accepts.",
      organizer: meeting.organizer_name
    )
  end

  defp held_sentence(meeting, :reschedule) do
    dgettext(
      "emails",
      "The new time is held for you in the meantime, so nobody else can take it. You'll get an email with the updated calendar entry as soon as %{organizer} accepts.",
      organizer: meeting.organizer_name
    )
  end

  defp subject_line(:booking, meeting, date) do
    dgettext("emails", "Request received: %{title} - %{date}", title: meeting.title, date: date)
  end

  defp subject_line(:reschedule, meeting, date) do
    dgettext("emails", "Reschedule requested: %{title} - %{date}",
      title: meeting.title,
      date: date
    )
  end

  defp previous_time_text(meeting, opts, locale) do
    case Keyword.get(opts, :previous_start_time) do
      %DateTime{} = previous ->
        dgettext("emails", "Previously scheduled for %{time}.",
          time:
            previous
            |> TimezoneHelper.convert_to_timezone(meeting.attendee_timezone || "UTC")
            |> Formatting.format_datetime(locale)
        )

      _unknown ->
        nil
    end
  end

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

  # The msgid carries no markup — the `<a>` is built here and passed in as
  # %{link}, so translators only ever see plain text and a placeholder, and
  # the href goes through the same URL validation every other link in these
  # templates gets before it reaches the sink.
  defp cancel_line(%Meeting{cancel_url: url}) do
    safe_url = Sanitise.sanitize_url(url)
    link_text = Sanitise.sanitize_for_email(dgettext("emails", "withdraw your request"))

    link_html =
      ~s(<a href="#{safe_url}" style="color:#{Styles.component_color(:link)}">#{link_text}</a>)

    """
    <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="16px 0 0 0">
      #{dgettext("emails", "Changed your mind? You can %{link} at any time.", link: link_html)}
    </mj-text>
    """
  end

  defp text_body_for({meeting, kind}, details, previous, locale) do
    """
    #{heading(kind)}

    #{dgettext("emails", "Hi %{name},", name: meeting.attendee_name)}

    #{text_intro(meeting, kind)}

    #{dgettext("emails", "REQUESTED TIME:")}
    #{dgettext("emails", "Date:")} #{Formatting.format_date_short(details.date, locale)}
    #{dgettext("emails", "Duration:")} #{Formatting.format_duration(details.duration, locale)}
    #{dgettext("emails", "Location:")} #{Formatting.format_location(details)}
    #{dgettext("emails", "Type:")} #{details.meeting_type}
    #{dgettext("emails", "Timezone:")} #{details.timezone}
    #{previous || ""}

    #{waiting_sentence(meeting, locale)}

    #{held_sentence(meeting, kind)}
    #{if meeting.cancel_url, do: "\n" <> dgettext("emails", "Withdraw your request:") <> "\n" <> meeting.cancel_url, else: ""}
    """
  end
end
