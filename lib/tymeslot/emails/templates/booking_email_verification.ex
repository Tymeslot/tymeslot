defmodule Tymeslot.Emails.Templates.BookingEmailVerification do
  @moduledoc """
  Asks an attendee to confirm their email address before a booking counts.

  Sent on a meeting type that requires verification. Until the attendee presses
  the button, the booking holds its slot but is not confirmed, and the organiser
  has been told nothing about it.

  Deliberately carries **no calendar file, no location or join link, and no
  cancel, reschedule or manage link**. The meeting `uid` opens the public
  cancel and reschedule pages, so it must not leave the system before the
  address is verified; for the same reason this template never calls
  `MeetingLinks.with_current_links/1`, which builds those links.
  """

  import Swoosh.Email

  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MeetingComponents,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    TextBodyHelper,
    TimezoneHelper
  }

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Helpers.LocaleFormat

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :alert

  @spec render(Meeting.t(), String.t()) :: Swoosh.Email.t()
  def render(%Meeting{} = meeting, verify_url) when is_binary(verify_url),
    do: render_held(meeting, verify_url, :booking)

  @doc """
  The same email for one seat of a group meeting. The slot row carries no
  attendee, so the seat supplies the recipient, locale, timezone and deadline.
  """
  @spec render_seat(Meeting.t(), ParticipantSchema.t(), String.t()) :: Swoosh.Email.t()
  def render_seat(%Meeting{} = slot, %ParticipantSchema{} = seat, verify_url)
      when is_binary(verify_url) do
    render_held(
      %{
        slot
        | attendee_name: seat.name,
          attendee_email: seat.email,
          attendee_timezone: seat.timezone,
          attendee_locale: seat.locale,
          verification_deadline_at: seat.verification_deadline_at
      },
      verify_url,
      :seat
    )
  end

  defp render_held(meeting, verify_url, held) do
    locale = RecipientLocale.attendee_locale(meeting)

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting = %{meeting | title: BookingTitle.localise(meeting)}
      attendee_time = TimezoneHelper.convert_to_attendee_timezone(meeting)
      details = meeting_details(meeting, attendee_time)

      intro = intro(meeting, held, locale)

      mjml_content = """
      #{MeetingComponents.meeting_details_table(details, locale)}

      <mj-text font-size="16px" color="#{Styles.ink_soft()}" line-height="24px" padding="16px 0 0 0">
        #{Sanitise.sanitize_for_email(intro)}
      </mj-text>

      #{Buttons.action_button(@intent, dgettext("emails_booking_requests", "Confirm booking"), verify_url, size: :large)}

      <mj-text font-size="14px" color="#{Styles.ink_muted()}" line-height="20px" padding="8px 0 0 0">
        #{Sanitise.sanitize_for_email(ignore_line())}
      </mj-text>
      """

      html_body =
        TemplateHelper.compile_system_template(
          mjml_content,
          heading(),
          dgettext(
            "emails_booking_requests",
            "Hi %{name}, your booking is not confirmed yet.",
            name: meeting.attendee_name
          ),
          intent: @intent,
          eyebrow: dgettext("emails_booking_requests", "Not confirmed"),
          stage_title: heading(),
          stage_subtitle:
            dgettext(
              "emails_booking_requests",
              "Hi %{name}, your booking is not confirmed yet.",
              name: meeting.attendee_name
            )
        )

      MjmlEmail.base_email()
      |> to({meeting.attendee_name, meeting.attendee_email})
      |> from({meeting.organizer_name, MjmlEmail.fetch_from_email()})
      |> MjmlEmail.put_reply_to(meeting.organizer_name, meeting.organizer_email)
      |> subject(
        dgettext("emails_booking_requests", "Confirm your booking with %{organizer}",
          organizer: meeting.organizer_name
        )
      )
      |> html_body(html_body)
      |> text_body(text_body_for(meeting, details, intro, verify_url, locale))
    end)
  end

  defp heading, do: dgettext("emails_booking_requests", "Please confirm your booking")

  # The deadline itself, on the attendee's clock, not the length of the hold:
  # the hold is capped at the meeting's start, and a resend never moves it.
  # Always with its date: the email may be read the next day, and a hold
  # running past midnight would otherwise read as a time already gone.
  #
  # A seat holds a place on a slot whose time other attendees may share, so
  # it is the place, not the time, that is held.
  defp intro(%Meeting{verification_deadline_at: %DateTime{} = deadline} = meeting, held, locale) do
    {local, _zone} = DateTimeUtils.shift_or_utc(deadline, meeting.attendee_timezone)

    by_deadline =
      %{start_time: local}
      |> Formatting.format_meeting_datetime(locale)
      |> LocaleFormat.with_article(:none, locale)

    intro_text(held, by_deadline)
  end

  defp intro_text(:booking, by_deadline) do
    dgettext(
      "emails_booking_requests",
      "Your booking is not confirmed yet. Click the button below by %{by_deadline} to confirm it, and we will hold the time for you until then.",
      by_deadline: by_deadline
    )
  end

  defp intro_text(:seat, by_deadline) do
    dgettext(
      "emails_booking_requests",
      "Your booking is not confirmed yet. Click the button below by %{by_deadline} to confirm it, and we will hold your place until then.",
      by_deadline: by_deadline
    )
  end

  defp ignore_line do
    dgettext(
      "emails_booking_requests",
      "If you did not make this booking, ignore this email. Nothing will be booked."
    )
  end

  # No location: the booking is not confirmed, so there is nothing to join.
  defp meeting_details(meeting, attendee_time) do
    %{
      date: attendee_time,
      start_time: attendee_time,
      start_time_attendee_tz: attendee_time,
      duration: meeting.duration,
      location: nil,
      meeting_type: meeting.meeting_type || dgettext("emails_booking_requests", "Meeting")
    }
  end

  defp text_body_for(meeting, details, intro, verify_url, locale) do
    """
    #{heading()}

    #{dgettext("emails_booking_requests", "Hi %{name},", name: meeting.attendee_name)}

    #{intro}

    #{TextBodyHelper.format_meeting_details(details, locale)}

    #{dgettext("emails_booking_requests", "Confirm booking")}:
    #{verify_url}

    #{ignore_line()}
    """
  end
end
