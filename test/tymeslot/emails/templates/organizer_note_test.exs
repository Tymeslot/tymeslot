defmodule Tymeslot.Emails.Templates.OrganizerNoteTest do
  @moduledoc """
  The organiser's note reaches everyone invited to the meeting: the attendee
  and any guests, in the confirmation and in the reminder, in both bodies.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.{AppointmentConfirmation, AppointmentReminder}
  import Tymeslot.EmailTestHelpers

  @note "Agenda: the Q3 roadmap. Bring your numbers."

  @renders [
    {AppointmentConfirmation, :attendee, "attendee@example.com"},
    {AppointmentConfirmation, :guest, "greg@example.com"},
    {AppointmentReminder, :attendee, "attendee@example.com"},
    {AppointmentReminder, :guest, "greg@example.com"}
  ]

  defp details(overrides) do
    build_appointment_details(
      Map.merge(
        %{
          guest_name: "Greg Guest",
          guest_accept_url: "https://tymeslot.example.com/guest/tok/accept",
          guest_decline_url: "https://tymeslot.example.com/guest/tok/decline"
        },
        overrides
      )
    )
  end

  for {template, role, recipient} <- @renders do
    @template template
    @role role
    @recipient recipient

    test "#{inspect(template)} as #{role} carries the note in both bodies" do
      email = @template.render(@role, @recipient, details(%{organizer_note: @note}))

      assert email.html_body =~ "Note from the organiser"
      assert email.html_body =~ @note
      assert email.text_body =~ "NOTE FROM THE ORGANISER:\n\"#{@note}\""
    end

    test "#{inspect(template)} as #{role} shows no note box without a note" do
      email = @template.render(@role, @recipient, details(%{organizer_note: nil}))

      refute email.html_body =~ "Note from the organiser"
      refute email.text_body =~ "NOTE FROM THE ORGANISER:"
    end
  end

  test "the guest's calendar file credits the note to the organiser" do
    email =
      AppointmentConfirmation.render(
        :attendee,
        "attendee@example.com",
        details(%{organizer_note: "Bring your numbers."})
      )

    [ics] = Enum.filter(email.attachments, &(&1.content_type == "text/calendar"))
    organizer_name = details(%{}).organizer_name

    # Long iCalendar lines are folded with CRLF and a space; unfold to match.
    unfolded = String.replace(ics.data, "\r\n ", "")

    assert unfolded =~ "Message from #{organizer_name}:\\nBring your numbers."
  end

  test "escapes markup in the note rather than rendering it" do
    email =
      AppointmentConfirmation.render(
        :attendee,
        "attendee@example.com",
        details(%{organizer_note: "<script>alert('x')</script>Hello"})
      )

    refute email.html_body =~ "<script>alert"
    assert email.html_body =~ "Hello"
  end
end
