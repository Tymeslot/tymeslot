defmodule Tymeslot.Emails.Templates.AppointmentConfirmationGuestTest do
  @moduledoc """
  Guest-side render tests for `AppointmentConfirmation`: recipient, subject
  line, RSVP action links, and the video join section.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  import Tymeslot.EmailTestHelpers

  defp guest_details(overrides \\ %{}) do
    build_appointment_details(
      Map.merge(
        %{
          guest_name: "Greg Guest",
          guest_accept_url: "https://tymeslot.example.com/guest/accept/tok",
          guest_decline_url: "https://tymeslot.example.com/guest/decline/tok"
        },
        overrides
      )
    )
  end

  describe "render/3 as guest" do
    test "sets recipient from the guest name and email" do
      email = AppointmentConfirmation.render(:guest, "greg@example.com", guest_details())

      assert email.to == [{"Greg Guest", "greg@example.com"}]
    end

    test "falls back to the email address when the guest has no name" do
      email =
        AppointmentConfirmation.render(
          :guest,
          "greg@example.com",
          guest_details(%{guest_name: nil})
        )

      assert email.to == [{"greg@example.com", "greg@example.com"}]
    end

    test "subject announces the invitation" do
      details = guest_details()
      email = AppointmentConfirmation.render(:guest, "greg@example.com", details)

      assert email.subject =~ "invited"
      assert email.subject =~ details.organizer_name
    end

    test "includes the RSVP links in both bodies" do
      email = AppointmentConfirmation.render(:guest, "greg@example.com", guest_details())

      assert email.html_body =~ "https://tymeslot.example.com/guest/accept/tok"
      assert email.html_body =~ "https://tymeslot.example.com/guest/decline/tok"
      assert email.text_body =~ "https://tymeslot.example.com/guest/accept/tok"
      assert email.text_body =~ "https://tymeslot.example.com/guest/decline/tok"
    end

    # Regression: the guest variant rendered no join link in either body, so a
    # guest invited to a video meeting could RSVP but had no way to attend.
    test "includes the video join link in both bodies" do
      details =
        guest_details(%{
          meeting_url: "https://meet.example.com/room-123",
          location_type: :video
        })

      email = AppointmentConfirmation.render(:guest, "greg@example.com", details)

      assert email.html_body =~ "https://meet.example.com/room-123"
      assert email.html_body =~ "Join when you&#39;re ready"
      assert email.html_body =~ "Join Meeting"
      assert email.text_body =~ "https://meet.example.com/room-123"
      assert email.text_body =~ "JOIN VIDEO MEETING"
    end

    # The participant URL is minted with the booker's name and email baked in;
    # it identifies that one person, so a third-party guest must not be handed
    # it. Guests get the identity-free room URL, matching the ICS attachment
    # this same email already carries.
    test "join link uses the room URL, not the booker's or host's personal URL" do
      details =
        guest_details(%{
          meeting_url: "https://meet.example.com/PLAIN-ROOM",
          organizer_video_url: "https://meet.example.com/HOST-TOKEN",
          attendee_video_url: "https://meet.example.com/PARTICIPANT-TOKEN"
        })

      email = AppointmentConfirmation.render(:guest, "greg@example.com", details)

      assert email.html_body =~ "PLAIN-ROOM"
      assert email.text_body =~ "PLAIN-ROOM"
      refute email.html_body =~ "HOST-TOKEN"
      refute email.text_body =~ "HOST-TOKEN"
      refute email.html_body =~ "PARTICIPANT-TOKEN"
      refute email.text_body =~ "PARTICIPANT-TOKEN"
    end

    test "no join section is rendered for a non-video meeting" do
      details =
        guest_details(%{
          meeting_url: nil,
          organizer_video_url: nil,
          attendee_video_url: nil,
          location: "Conference Room A"
        })

      email = AppointmentConfirmation.render(:guest, "greg@example.com", details)

      refute email.html_body =~ "Join Meeting"
      refute email.text_body =~ "JOIN VIDEO MEETING"
    end

    test "includes an ICS calendar attachment" do
      details = guest_details()
      email = AppointmentConfirmation.render(:guest, "greg@example.com", details)

      assert %Swoosh.Attachment{filename: filename} =
               Enum.find(email.attachments, &(&1.content_type =~ "text/calendar"))

      assert filename =~ details.uid
      assert filename =~ ".ics"
    end

    test "subject is free of CR/LF when the organiser name carries a header payload" do
      details = guest_details(%{organizer_name: "John\r\nCc: someone@evil.com"})

      email = AppointmentConfirmation.render(:guest, "greg@example.com", details)

      refute email.subject =~ "\r"
      refute email.subject =~ "\n"
    end
  end
end
