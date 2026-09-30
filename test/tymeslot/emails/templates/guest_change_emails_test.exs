defmodule Tymeslot.Emails.Templates.GuestChangeEmailsTest do
  @moduledoc """
  Guest-side render tests for `AppointmentRescheduled` and
  `AppointmentCancellation`: guests hear about changes to a booking they were
  invited to, with their own RSVP links on a reschedule and never the booker's
  links to reschedule or cancel.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.Emails.Templates.AppointmentRescheduled

  @original_start ~U[2026-01-14 09:00:00Z]

  defp guest_details(overrides \\ %{}) do
    build_appointment_details(
      Map.merge(
        %{
          guest_name: "Greg Guest",
          guest_accept_url: "https://tymeslot.example.com/guest/tok/accept",
          guest_decline_url: "https://tymeslot.example.com/guest/tok/decline",
          original_start_time: @original_start,
          original_start_time_attendee_tz: @original_start,
          ical_sequence: 2
        },
        overrides
      )
    )
  end

  defp calendar_attachment(email),
    do: Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

  describe "AppointmentRescheduled.render/3 as guest" do
    test "addresses the guest and names the new time" do
      details = guest_details()
      email = AppointmentRescheduled.render(:guest, "greg@example.com", details)

      assert email.to == [{"Greg Guest", "greg@example.com"}]
      assert email.subject =~ "Rescheduled"
      assert email.html_body =~ "has been moved to a new time"
      assert email.html_body =~ "Previously scheduled for"
    end

    test "asks again with the guest's RSVP links in both bodies" do
      email = AppointmentRescheduled.render(:guest, "greg@example.com", guest_details())

      for body <- [email.html_body, email.text_body] do
        assert body =~ "https://tymeslot.example.com/guest/tok/accept"
        assert body =~ "https://tymeslot.example.com/guest/tok/decline"
      end
    end

    test "carries none of the booker's links to change the booking" do
      details = guest_details()
      email = AppointmentRescheduled.render(:guest, "greg@example.com", details)

      for body <- [email.html_body, email.text_body] do
        refute body =~ details.reschedule_url
        refute body =~ details.cancel_url
      end
    end

    test "gives the shared room link, not the booker's own join link" do
      details = guest_details()
      email = AppointmentRescheduled.render(:guest, "greg@example.com", details)

      assert email.html_body =~ details.meeting_url
      refute email.html_body =~ details.attendee_video_url
    end

    # On a server that admits only a link carrying a token, the bare room URL
    # opens nothing, so the payload carries a link of the guests' own. It is
    # preferred over the room URL wherever it is present.
    test "prefers the guests' own link over the bare room URL" do
      details = guest_details(%{guest_video_url: "https://meet.example.com/room?jwt=GUEST-TOKEN"})
      email = AppointmentRescheduled.render(:guest, "greg@example.com", details)

      for body <- [email.html_body, email.text_body] do
        assert body =~ "jwt=GUEST-TOKEN"
        refute body =~ details.attendee_video_url
      end
    end

    test "attaches a calendar update that supersedes the invitation" do
      # The guest's entry must be replaced exactly like the attendee's, so both
      # carry the same SEQUENCE for the same booking revision. Compared rather
      # than pinned to a number, because how the value is derived from the
      # stored `ical_sequence` is the attendee template's business.
      details = guest_details()

      guest_ics =
        calendar_attachment(AppointmentRescheduled.render(:guest, "greg@example.com", details))

      attendee_ics =
        calendar_attachment(
          AppointmentRescheduled.render(:attendee, details.attendee_email, details)
        )

      assert guest_ics.data =~ "METHOD:PUBLISH"
      assert sequence(guest_ics) == sequence(attendee_ics)
      assert sequence(guest_ics) > 0
    end

    test "renders in the booking's locale" do
      en = AppointmentRescheduled.render(:guest, "greg@example.com", guest_details())

      de =
        AppointmentRescheduled.render(
          :guest,
          "greg@example.com",
          guest_details(%{attendee_locale: "de"})
        )

      refute de.subject == en.subject
    end
  end

  describe "AppointmentCancellation.render/3 as guest" do
    test "tells the guest the meeting is off" do
      details = guest_details()
      email = AppointmentCancellation.render(:guest, "greg@example.com", details)

      assert email.to == [{"Greg Guest", "greg@example.com"}]
      assert email.subject =~ "Cancelled"
      assert email.html_body =~ "has been cancelled"
    end

    test "offers neither RSVP links nor the booker's links" do
      details = guest_details()
      email = AppointmentCancellation.render(:guest, "greg@example.com", details)

      for body <- [email.html_body, email.text_body] do
        refute body =~ details.guest_accept_url
        refute body =~ details.guest_decline_url
        refute body =~ details.reschedule_url
        refute body =~ details.cancel_url
      end
    end

    test "attaches a calendar cancellation" do
      email = AppointmentCancellation.render(:guest, "greg@example.com", guest_details())

      assert ics = calendar_attachment(email)
      assert ics.data =~ "STATUS:CANCELLED"
      assert ics.data =~ "SEQUENCE:3"
    end
  end

  defp sequence(ics) do
    [_match, value] = Regex.run(~r/^SEQUENCE:(\d+)/m, ics.data)
    String.to_integer(value)
  end

  describe "naming who invited the guest" do
    defp named(invited_by),
      do:
        guest_details(%{
          attendee_name: "Bella Booker",
          organizer_name: "Olive Host",
          guest_invited_by: invited_by
        })

    test "a reschedule names the booker for a guest brought on the booking page" do
      email = AppointmentRescheduled.render(:guest, "greg@example.com", named(:booker))

      for body <- [email.html_body, email.text_body] do
        assert body =~ "meeting with Olive Host that Bella Booker invited you to"
      end
    end

    test "a reschedule names the host for a guest the host added" do
      email = AppointmentRescheduled.render(:guest, "greg@example.com", named(:organizer))

      assert email.html_body =~
               "the meeting Olive Host invited you to has been moved to a new time."

      assert email.text_body =~
               "The meeting Olive Host invited you to has been moved to a new time."

      for body <- [email.html_body, email.text_body], do: refute(body =~ "Bella Booker")
    end

    test "a cancellation names the booker for a guest brought on the booking page" do
      email = AppointmentCancellation.render(:guest, "greg@example.com", named(:booker))

      for body <- [email.html_body, email.text_body] do
        assert body =~ "meeting with Olive Host that Bella Booker invited you to"
      end
    end

    test "a cancellation names the host for a guest the host added" do
      email = AppointmentCancellation.render(:guest, "greg@example.com", named(:organizer))

      assert email.html_body =~ "the meeting Olive Host invited you to has been cancelled."
      assert email.text_body =~ "The meeting Olive Host invited you to has been cancelled."

      for body <- [email.html_body, email.text_body], do: refute(body =~ "Bella Booker")
    end
  end
end
