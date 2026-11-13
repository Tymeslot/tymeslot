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
end
