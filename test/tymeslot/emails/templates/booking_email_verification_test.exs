defmodule Tymeslot.Emails.Templates.BookingEmailVerificationTest do
  @moduledoc """
  The email that asks an attendee to confirm their address: what it says, in
  whose language, and what it must never carry before the address is verified.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  alias Ecto.UUID
  alias Tymeslot.Emails.Templates.BookingEmailVerification
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantSchema

  @verify_url "https://tymeslot.test/verify-booking/signed-token"

  defp meeting(attrs \\ %{}) do
    struct!(
      %Meeting{
        id: UUID.generate(),
        uid: "uid-9f3b7c1d-secret",
        title: "Strategy call",
        meeting_type: "Strategy call",
        start_time: ~U[2026-09-01 13:00:00Z],
        end_time: ~U[2026-09-01 13:30:00Z],
        duration: 30,
        location: "Video Call",
        organizer_name: "Sam Host",
        organizer_email: "sam@example.com",
        attendee_name: "Alex Guest",
        attendee_email: "alex@example.com",
        attendee_timezone: "Europe/Ljubljana",
        attendee_locale: "en",
        status: :awaiting_verification,
        verification_deadline_at: ~U[2026-08-30 10:30:00Z],
        cancel_url: "https://tymeslot.test/meeting/cancel/uid-9f3b7c1d-secret",
        reschedule_url: "https://tymeslot.test/meeting/reschedule/uid-9f3b7c1d-secret"
      },
      attrs
    )
  end

  test "the email asks the attendee to confirm by the deadline, in their timezone" do
    email = BookingEmailVerification.render(meeting(), @verify_url)

    # 10:30 UTC is 12:30 in Ljubljana in summer.
    for body <- [email.html_body, email.text_body] do
      assert body =~ @verify_url
      assert body =~ "by 30 August 2026 at 12:30 PM CEST"
      refute body =~ "within"
      assert body =~ "Confirm booking"
    end

    assert email.subject == "Confirm your booking with Sam Host"
    assert email.to == [{"Alex Guest", "alex@example.com"}]
  end

  # The hold is capped at the meeting's start, so a booking made ten minutes
  # before it must not promise thirty.
  test "a booking made 10 minutes before its start names the start as the deadline" do
    start_time = ~U[2026-09-01 13:00:00Z]

    %{verification_deadline_at: deadline} =
      EmailVerification.gate_attributes(~U[2026-09-01 12:50:00Z], start_time)

    email =
      BookingEmailVerification.render(
        meeting(%{start_time: start_time, verification_deadline_at: deadline}),
        @verify_url
      )

    assert email.text_body =~ "by 1 September 2026 at 03:00 PM CEST"
    refute email.text_body =~ "03:20 PM"
  end

  # Without its date, a hold running past midnight on the attendee's clock
  # would read as a time already gone.
  test "a deadline past the attendee's midnight names its own date" do
    # 22:10 UTC on 30 August is 00:10 on 31 August in Ljubljana.
    email =
      BookingEmailVerification.render(
        meeting(%{verification_deadline_at: ~U[2026-08-30 22:10:00Z]}),
        @verify_url
      )

    for body <- [email.html_body, email.text_body] do
      assert body =~ "by 31 August 2026 at 12:10 AM CEST"
    end
  end

  test "the email is in the attendee's language" do
    email = BookingEmailVerification.render(meeting(%{attendee_locale: "de"}), @verify_url)

    # German puts the day first ("1. September 2026"), English the month
    # ("September 1, 2026"), so the date proves the locale was applied.
    assert email.text_body =~ "1. September 2026"
    assert email.html_body =~ "1. September 2026"
    refute email.html_body =~ "September 1, 2026"
  end

  # Italian puts the article before the deadline, elided before a day read
  # with a vowel, so it comes from the code rather than the translation.
  test "an Italian deadline carries the article its day is read with" do
    eighth = meeting(%{attendee_locale: "it", verification_deadline_at: ~U[2026-10-08 08:30:00Z]})
    ninth = meeting(%{attendee_locale: "it", verification_deadline_at: ~U[2026-10-09 08:30:00Z]})

    assert BookingEmailVerification.render(eighth, @verify_url).text_body =~
             "entro l'8 ottobre 2026 alle 10:30"

    assert BookingEmailVerification.render(ninth, @verify_url).text_body =~
             "entro il 9 ottobre 2026 alle 10:30"
  end

  test "the email carries no uid, no manage links and no attachment" do
    email = BookingEmailVerification.render(meeting(), @verify_url)
    uid = meeting().uid

    refute email.html_body =~ uid
    refute email.text_body =~ uid
    refute email.html_body =~ "/meeting/cancel"
    refute email.html_body =~ "/meeting/reschedule"
    # The only attachment is the inline brand logo, never a calendar file.
    refute Enum.any?(email.attachments, &(&1.content_type =~ "calendar"))
    assert Enum.all?(email.attachments, &(&1.type == :inline))
  end

  test "the seat email is in the seat's language and timezone" do
    slot = meeting(%{attendee_name: nil, attendee_email: nil, attendee_locale: nil})

    seat =
      %ParticipantSchema{
        name: "Mia Seat",
        email: "mia@example.com",
        timezone: "America/New_York",
        locale: "de",
        management_token: "management-token-secret",
        verification_deadline_at: ~U[2026-08-30 10:30:00Z]
      }

    email = BookingEmailVerification.render_seat(slot, seat, @verify_url)

    assert email.to == [{"Mia Seat", "mia@example.com"}]
    assert email.text_body =~ @verify_url
    assert email.text_body =~ "1. September 2026"
    # 10:30 UTC is 06:30 in New York in summer.
    assert email.text_body =~ "EDT"
    refute email.text_body =~ "CEST"
    refute email.html_body =~ "management-token-secret"
    refute email.html_body =~ "uid-9f3b7c1d-secret"
    refute email.text_body =~ "/meeting/"
  end

  # A slot's own deadline is its first seat's; every later seat is held
  # until its own.
  test "the seat email names the seat's deadline, not the slot's" do
    slot = meeting(%{attendee_name: nil, attendee_email: nil, attendee_locale: nil})

    seat = %ParticipantSchema{
      name: "Mia Seat",
      email: "mia@example.com",
      timezone: "Europe/Ljubljana",
      locale: "en",
      verification_deadline_at: ~U[2026-08-31 08:15:00Z]
    }

    email = BookingEmailVerification.render_seat(slot, seat, @verify_url)

    # 08:15 UTC is 10:15 in Ljubljana in summer; the slot's is 30 August.
    for body <- [email.html_body, email.text_body] do
      assert body =~ "by 31 August 2026 at 10:15 AM CEST"
      refute body =~ "30 August 2026 at 12:30 PM"
    end
  end

  # A seat shares its slot's time with other attendees, so the email holds
  # the booker's place, not the time.
  test "the seat email holds the booker's place, not the time" do
    slot = meeting(%{attendee_name: nil, attendee_email: nil, attendee_locale: nil})

    seat = %ParticipantSchema{
      name: "Mia Seat",
      email: "mia@example.com",
      timezone: "Europe/Ljubljana",
      locale: "en",
      verification_deadline_at: ~U[2026-08-30 10:30:00Z]
    }

    email = BookingEmailVerification.render_seat(slot, seat, @verify_url)

    for body <- [email.html_body, email.text_body] do
      assert body =~ "we will hold your place until then"
      refute body =~ "hold the time"
    end

    assert BookingEmailVerification.render(meeting(), @verify_url).text_body =~
             "we will hold the time for you until then"
  end
end
