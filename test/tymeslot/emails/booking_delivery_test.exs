defmodule Tymeslot.Emails.BookingDeliveryTest do
  @moduledoc "Verifies that booking rendering cannot bypass sender ownership resolution."

  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :unit

  alias Swoosh.Email
  alias Tymeslot.Emails.BookingDelivery
  alias Tymeslot.Emails.EmailService.AppointmentEmails
  alias Tymeslot.Emails.EmailService.CalendarEmails
  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.Meetings.MeetingSchema

  test "prepared recipient copies reuse the same explicit platform identity" do
    sender = Sender.platform(123)

    resource = %{
      organizer_user_id: 123,
      email_sender: sender,
      attendee_email: "guest@example.com"
    }

    assert {:ok, ^resource, ^sender} = BookingDelivery.prepare(resource)
    assert {:ok, ^resource, ^sender} = BookingDelivery.prepare(resource)
  end

  test "a sender belonging to another organizer prevents rendering and delivery" do
    resource = %{organizer_user_id: 456, email_sender: Sender.platform(123)}

    assert {:error, :invalid_sender} =
             BookingDelivery.deliver(resource, fn _details ->
               send(self(), :rendered)
               Email.new()
             end)

    refute_received :rendered
  end

  test "aggregate confirmation and reminder errors preserve both recipient results" do
    resource = %{organizer_user_id: 456, email_sender: Sender.platform(123)}
    errors = {{:error, :invalid_sender}, {:error, :invalid_sender}}

    assert AppointmentEmails.send_appointment_confirmations(resource) == errors
    assert AppointmentEmails.send_appointment_reminders(resource, "1 hour") == errors
  end

  test "invalid booking details fail at the helper boundary" do
    assert {:error, :invalid_booking} = BookingDelivery.prepare(nil)
  end

  test "the organizer's meeting-end summary validates the booking sender before rendering" do
    meeting = %MeetingSchema{
      id: "meeting-id",
      organizer_user_id: 456,
      email_sender: Sender.platform(123)
    }

    assert {:error, :invalid_sender} =
             CalendarEmails.send_end_change_to_organizer(meeting, "host@example.com", %{})
  end
end
