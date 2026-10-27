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

  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.Bookings.MeetingLinks

  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
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

  alias Tymeslot.Utils.DateTimeUtils

  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  use Gettext, backend: TymeslotWeb.Gettext

  # Amber rather than the confirmed brand colour: the band is the first thing
  # read, and it should not say "done".
  @intent :alert

  @spec render(Meeting.t(), keyword()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, opts \\ []) do
    locale = RecipientLocale.attendee_locale(meeting)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      # The stored title is in the organiser's language; the booker reads it in
      # theirs. The links are built now, not read from the booking-time copy.
      meeting =
        %{MeetingLinks.with_current_links(meeting) | title: BookingTitle.localise(meeting)}

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
            "emails_booking_requests",
            "Hi %{name}, we've passed your request to %{organizer}. It isn't confirmed yet.",
            name: meeting.attendee_name,
            organizer: meeting.organizer_name
          ),
          intent: @intent,
          eyebrow: dgettext("emails_booking_requests", "Awaiting confirmation"),
          stage_title: stage_title(kind),
          stage_subtitle: personal_sentence(meeting, kind)
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> MjmlEmail.put_reply_to(meeting.organizer_name, meeting.organizer_email)
      |> subject(subject_line(kind, meeting, Formatting.format_date_short(attendee_time, locale)))
      |> html_body(html_body)
      |> text_body(text_body_for({meeting, kind}, details, previous, locale))
    end)
  end

  # Confirmed once already: the invitee is moving a meeting, not booking one.
  defp rescheduled?(%Meeting{first_announced_at: %DateTime{}}), do: true
  defp rescheduled?(_meeting), do: false

  defp heading(:booking), do: dgettext("emails_booking_requests", "Booking Request Received")

  defp heading(:reschedule),
    do: dgettext("emails_booking_requests", "Reschedule Request Received")

  defp stage_title(:booking), do: dgettext("emails_booking_requests", "Request received")
  defp stage_title(:reschedule), do: dgettext("emails_booking_requests", "Reschedule requested")

  defp requested_time_title(:booking), do: dgettext("emails_booking_requests", "Requested Time")

  defp requested_time_title(:reschedule),
    do: dgettext("emails_booking_requests", "Requested New Time")

  defp personal_sentence(meeting, :booking) do
    dgettext(
      "emails_booking_requests",
      "Hi %{name}, %{organizer} confirms each booking personally, so this isn't final yet.",
      name: meeting.attendee_name,
      organizer: meeting.organizer_name
    )
  end

  defp personal_sentence(meeting, :reschedule) do
    dgettext(
      "emails_booking_requests",
      "Hi %{name}, %{organizer} confirms each change personally, so the new time isn't final yet.",
      name: meeting.attendee_name,
      organizer: meeting.organizer_name
    )
  end

  defp text_intro(meeting, :booking) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} confirms each booking personally, so this isn't final yet.",
      organizer: meeting.organizer_name
    )
  end

  defp text_intro(meeting, :reschedule) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} confirms each change personally, so the new time isn't final yet.",
      organizer: meeting.organizer_name
    )
  end

  defp held_sentence(meeting, :booking) do
    dgettext(
      "emails_booking_requests",
      "This time is held for you in the meantime, so nobody else can take it. You'll get a confirmation with the calendar invite as soon as %{organizer} accepts.",
      organizer: meeting.organizer_name
    )
  end

  defp held_sentence(meeting, :reschedule) do
    dgettext(
      "emails_booking_requests",
      "The new time is held for you in the meantime, so nobody else can take it. You'll get an email with the updated calendar entry as soon as %{organizer} accepts.",
      organizer: meeting.organizer_name
    )
  end

  defp subject_line(:booking, meeting, date) do
    dgettext("emails_booking_requests", "Request received: %{title} - %{date}",
      title: meeting.title,
      date: date
    )
  end

  defp subject_line(:reschedule, meeting, date) do
    dgettext("emails_booking_requests", "Reschedule requested: %{title} - %{date}",
      title: meeting.title,
      date: date
    )
  end

  defp previous_time_text(meeting, opts, locale) do
    case Keyword.get(opts, :previous_start_time) do
      %DateTime{} = previous ->
        dgettext("emails_booking_requests", "Previously scheduled for %{time}.",
          time:
            previous
            |> DateTimeUtils.convert_to_timezone(meeting.attendee_timezone || "UTC")
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
      meeting_type: meeting.meeting_type || dgettext("emails_booking_requests", "Meeting")
    }
  end

  # Naming the deadline is what makes the wait tolerable. Where the request
  # has no deadline recorded we say nothing rather than inventing one.
  defp waiting_sentence(%Meeting{approval_deadline_at: nil} = meeting, _locale) do
    dgettext(
      "emails_booking_requests",
      "%{organizer} will review your request and get back to you shortly.",
      organizer: meeting.organizer_name
    )
  end

  defp waiting_sentence(%Meeting{} = meeting, locale) do
    deadline =
      meeting.approval_deadline_at
      |> DateTimeUtils.convert_to_timezone(meeting.attendee_timezone || "UTC")
      |> Formatting.format_datetime(locale)

    dgettext("emails_booking_requests", "%{organizer} will reply by %{deadline} at the latest.",
      organizer: meeting.organizer_name,
      deadline: deadline
    )
  end

  # The msgid carries no markup — the `<a>` is built here and passed in as
  # %{link}, so translators only ever see plain text and a placeholder, and
  # the href goes through the same URL validation every other link in these
  # templates gets before it reaches the sink.
  defp cancel_line(%Meeting{cancel_url: url}) do
    case Sanitise.sanitize_url(url) do
      nil -> ""
      safe_url -> withdraw_line(safe_url)
    end
  end

  defp withdraw_line(safe_url) do
    link_text =
      Sanitise.sanitize_for_email(dgettext("emails_booking_requests", "withdraw your request"))

    link_html =
      ~s(<a href="#{safe_url}" style="color:#{Styles.component_color(:link)}">#{link_text}</a>)

    """
    <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="16px 0 0 0">
      #{dgettext("emails_booking_requests", "Changed your mind? You can %{link} at any time.", link: link_html)}
    </mj-text>
    """
  end

  defp text_body_for({meeting, kind}, details, previous, locale) do
    """
    #{heading(kind)}

    #{dgettext("emails_booking_requests", "Hi %{name},", name: meeting.attendee_name)}

    #{text_intro(meeting, kind)}

    #{dgettext("emails_booking_requests", "REQUESTED TIME:")}
    #{TextBodyHelper.format_meeting_details(details, locale)}
    #{previous || ""}

    #{waiting_sentence(meeting, locale)}

    #{held_sentence(meeting, kind)}
    #{if Sanitise.safe_url?(meeting.cancel_url), do: "\n" <> dgettext("emails_booking_requests", "Withdraw your request:") <> "\n" <> meeting.cancel_url, else: ""}
    """
  end
end
