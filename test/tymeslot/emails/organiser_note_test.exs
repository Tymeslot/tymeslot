defmodule Tymeslot.Emails.OrganiserNoteTest do
  @moduledoc """
  The note a host writes when creating a meeting reaches the people they
  invited — the main guest and everyone added beside them.

  It used to be shown only to the organiser, which is right for a note left by
  the person booking and useless for one the host wrote to be read.
  """

  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Emails.Templates.AppointmentConfirmation

  import Tymeslot.EmailTestHelpers

  defp details(from) do
    build_appointment_details(%{
      attendee_message: "Meet at the side entrance.",
      message_from: from,
      guest_name: "Carol",
      guest_accept_url: "https://example.com/guest/tok/accept",
      guest_decline_url: "https://example.com/guest/tok/decline"
    })
  end

  # ICS folds every line at 75 octets (RFC 5545), so a heading can be split
  # mid-word in the raw file. Unfolding first is what makes an assertion about
  # its text mean anything.
  defp calendar_text(email) do
    case Enum.find(email.attachments, &String.ends_with?(&1.filename, ".ics")) do
      nil -> flunk("no calendar file attached: #{inspect(email.attachments)}")
      ics -> String.replace(ics.data, "\r\n ", "")
    end
  end

  defp host_note, do: details(:organiser)
  defp booker_note, do: details(:attendee)

  describe "a note the host wrote" do
    test "reaches the main guest" do
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", host_note())

      assert email.html_body =~ "Meet at the side entrance."
      assert email.html_body =~ "Message from the organiser"
    end

    test "reaches a guest added beside them" do
      email = AppointmentConfirmation.render(:guest, "carol@example.com", host_note())

      assert email.html_body =~ "Meet at the side entrance."
      assert email.html_body =~ "Message from the organiser"
    end

    test "still reaches the organiser's own copy" do
      email = AppointmentConfirmation.render(:organizer, "organizer@example.com", host_note())

      assert email.html_body =~ "Meet at the side entrance."
      assert email.html_body =~ "Message from the organiser"
    end
  end

  describe "who invited whom" do
    test "names the host on a meeting they created" do
      email = AppointmentConfirmation.render(:guest, "carol@example.com", host_note())

      # The host did the inviting, and the meeting is with the main guest.
      assert email.html_body =~
               "John Organizer has invited you as a guest to this meeting with Jane Attendee"

      refute email.html_body =~ "Jane Attendee has invited you"
    end

    test "names the booker on a meeting booked through a booking page" do
      email = AppointmentConfirmation.render(:guest, "carol@example.com", booker_note())

      assert email.html_body =~
               "Jane Attendee has invited you as a guest to this meeting with John Organizer"

      refute email.html_body =~ "John Organizer has invited you"
    end
  end

  describe "the calendar file" do
    test "credits the host with their own note" do
      email = AppointmentConfirmation.render(:guest, "carol@example.com", host_note())
      ics = calendar_text(email)

      assert ics =~ "Message from the organiser:"
      refute ics =~ "Message from Jane Attendee:"
    end

    test "credits the booker with theirs" do
      email = AppointmentConfirmation.render(:guest, "carol@example.com", booker_note())
      ics = calendar_text(email)

      assert ics =~ "Message from Jane Attendee:"
      refute ics =~ "Message from the organiser:"
    end
  end

  describe "a note the person booking left" do
    test "goes to the organiser, headed as theirs" do
      email = AppointmentConfirmation.render(:organizer, "organizer@example.com", booker_note())

      assert email.html_body =~ "Meet at the side entrance."
      assert email.html_body =~ "Message from attendee"
    end

    test "is not echoed back to the person who wrote it" do
      email = AppointmentConfirmation.render(:attendee, "attendee@example.com", booker_note())

      refute email.html_body =~ "Meet at the side entrance."
    end

    test "is not shown to the other guests either" do
      email = AppointmentConfirmation.render(:guest, "carol@example.com", booker_note())

      refute email.html_body =~ "Meet at the side entrance."
    end
  end
end
