defmodule Tymeslot.Emails.Templates.BookingReplyToTest do
  @moduledoc """
  Who a reply to a booking email reaches. Every booking email is sent from
  the instance's own address, which is often a no-reply mailbox, so each one
  carries a `Reply-To` naming the other party: the organiser on the
  attendee's and guests' copies, the attendee on the organiser's.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :bookings

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.Emails.Templates.AppointmentReminder
  alias Tymeslot.Emails.Templates.AppointmentRescheduled
  alias Tymeslot.Emails.Templates.CalendarInvitation
  alias Tymeslot.Emails.Templates.EventUpdateNotification

  @organiser {"John Organizer", "organizer@example.com"}
  @attendee {"Jane Attendee", "attendee@example.com"}

  @templates [AppointmentConfirmation, AppointmentReminder, AppointmentRescheduled]

  defp details do
    build_appointment_details(%{
      guest_name: "Greg Guest",
      guest_accept_url: "https://tymeslot.example.com/guest/accept/tok",
      guest_decline_url: "https://tymeslot.example.com/guest/decline/tok",
      original_date: ~D[2026-01-14],
      original_start_time: ~U[2026-01-14 09:00:00Z],
      original_start_time_owner_tz: ~U[2026-01-14 09:00:00Z],
      original_start_time_attendee_tz: ~U[2026-01-14 09:00:00Z],
      original_end_time: ~U[2026-01-14 10:00:00Z]
    })
  end

  defp instance_sender, do: {configured(:from_name), configured(:from_email)}

  for template <- @templates do
    describe "#{inspect(template)}" do
      test "the attendee's copy replies to the organiser" do
        email = unquote(template).render(:attendee, "attendee@example.com", details())

        assert email.reply_to == @organiser
        assert email.from == instance_sender()
      end

      test "a guest's copy replies to the organiser" do
        email = unquote(template).render(:guest, "greg@example.com", details())

        assert email.reply_to == @organiser
        assert email.from == instance_sender()
      end

      test "the organiser's copy replies to the attendee" do
        email = unquote(template).render(:organizer, "organizer@example.com", details())

        assert email.reply_to == @attendee
        assert email.from == instance_sender()
      end
    end
  end

  describe "AppointmentCancellation" do
    test "the attendee's copy replies to the organiser" do
      email = AppointmentCancellation.render(:attendee, "attendee@example.com", details())

      assert email.reply_to == @organiser
      assert email.from == instance_sender()
    end

    test "a participant's notice of giving up their spot replies to the organiser" do
      email =
        AppointmentCancellation.render(
          :attendee,
          "attendee@example.com",
          Map.put(details(), :seat_given_up, true)
        )

      assert email.subject =~ "Spot cancelled"
      assert email.reply_to == @organiser
      assert email.from == instance_sender()
    end

    test "a guest's copy replies to the organiser" do
      email = AppointmentCancellation.render(:guest, "greg@example.com", details())

      assert email.reply_to == @organiser
      assert email.from == instance_sender()
    end

    test "the organiser's copy replies to the attendee" do
      email = AppointmentCancellation.render(:organizer, "organizer@example.com", details())

      assert email.reply_to == @attendee
      assert email.from == instance_sender()
    end
  end

  describe "CalendarInvitation" do
    test "replies to the organiser" do
      email = CalendarInvitation.render("guest@example.com", build_invitation_details())

      assert email.reply_to == {"Test Organiser", "organiser@example.com"}
      assert email.from == instance_sender()
    end
  end

  describe "EventUpdateNotification" do
    test "replies to the organiser" do
      email = EventUpdateNotification.render("guest@example.com", build_event_update_details())

      assert email.reply_to == {"Test Organiser", "organiser@example.com"}
      assert email.from == instance_sender()
    end
  end

  # Reads the sender identity from config rather than from MjmlEmail, so the
  # assertions stay independent of the module under test.
  defp configured(key), do: Application.get_env(:tymeslot, :email)[key]
end
