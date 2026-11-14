defmodule Tymeslot.Emails.Templates.BookingSenderTest do
  @moduledoc """
  Verifies booking From identities while preserving translated content,
  reply addresses and calendar identities.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :bookings

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Shared.MjmlEmail
  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.Emails.Templates.AppointmentReminder
  alias Tymeslot.Emails.Templates.AppointmentRescheduled
  alias Tymeslot.Emails.Templates.BookingRequestOutcome
  alias Tymeslot.Emails.Templates.BookingRequestReceived
  alias Tymeslot.Emails.Templates.ExternalBookingChange
  alias Tymeslot.EmailSending.Sender
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  @templates [
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled,
    AppointmentCancellation
  ]

  for template <- @templates, role <- [:attendee, :organizer, :guest] do
    test "#{inspect(template)} #{role} uses the explicit From and keeps the other party as Reply-To" do
      details = details()
      email = unquote(template).render(unquote(role), "recipient@example.com", details)

      assert email.from == {"Customer bookings", "bookings@customer.example"}

      expected =
        if unquote(role) == :organizer,
          do: {details.attendee_name, details.attendee_email},
          else: {details.organizer_name, details.organizer_email}

      assert email.reply_to == expected
    end
  end

  test "the platform address remains a valid Reply-To when a custom From is selected" do
    platform_address = Application.fetch_env!(:tymeslot, :email)[:from_email]
    details = Map.put(details(), :organizer_email, platform_address)

    email = AppointmentConfirmation.render(:attendee, details.attendee_email, details)

    assert email.reply_to == {details.organizer_name, platform_address}
  end

  test "Reply-To is omitted when the other party already owns the selected From address" do
    details = Map.put(details(), :organizer_email, "bookings@customer.example")

    email = AppointmentConfirmation.render(:attendee, details.attendee_email, details)

    assert email.reply_to == nil
  end

  test "organizer booking copies direct replies to the attendee without another calendar invitation" do
    details = details()
    email = MjmlEmail.base_organizer_email(details.organizer_email, details)

    assert email.from == {"Customer bookings", "bookings@customer.example"}
    assert email.to == [{details.organizer_name, details.organizer_email}]
    assert email.reply_to == {details.attendee_name, details.attendee_email}
    refute Enum.any?(email.attachments, &String.starts_with?(&1.content_type, "text/calendar"))
  end

  test "request templates preserve the configured display name instead of replacing it with the organizer" do
    meeting =
      build(:meeting,
        organizer_name: "Different organizer name",
        email_sender: sender(),
        status: :pending_approval
      )

    for email <- [
          BookingRequestReceived.render(meeting),
          BookingRequestOutcome.render(:declined, meeting)
        ] do
      assert email.from == {"Customer bookings", "bookings@customer.example"}
      assert email.reply_to == {meeting.organizer_name, meeting.organizer_email}
    end
  end

  test "translated attendee and original organizer copies keep the same SMTP identity" do
    owner = insert(:user)
    insert(:profile, user: owner)
    sender = %{sender() | owner_id: owner.id}
    question = %{"id" => "company", "type" => "short_text", "label" => "Company", "position" => 0}
    translated_question = Map.put(question, "label", "Firma")

    meeting =
      build(:meeting,
        organizer_user_id: owner.id,
        organizer_email: owner.email,
        email_sender: sender,
        title: "Intro call with Test Attendee",
        summary: nil,
        meeting_type: "Intro call",
        description: "Discuss your plans",
        location_kind: :custom,
        location: "Garden pavilion",
        attendee_locale: "de",
        ical_sequence: 4,
        custom_fields_snapshot: [question],
        custom_field_answers: %{"company" => "Acme"},
        attendee_texts: %{
          "de" => %{
            "meeting_type" => "Erstgespräch",
            "description" => "Ihre Ziele besprechen",
            "location" => "Gartenpavillon",
            "custom_fields_snapshot" => [translated_question]
          }
        }
      )

    attendee_details = AppointmentBuilder.from_meeting(meeting)
    organizer_details = AppointmentBuilder.organizer_copy(attendee_details, meeting)

    assert attendee_details.title =~ "Erstgespräch"
    assert attendee_details.uid == meeting.calendar_uid
    assert attendee_details.meeting_type == "Erstgespräch"
    assert attendee_details.description == "Ihre Ziele besprechen"
    assert organizer_details.title == meeting.title
    assert organizer_details.uid == meeting.calendar_uid
    assert organizer_details.meeting_type == meeting.meeting_type
    assert organizer_details.description == meeting.description

    attendee = AppointmentConfirmation.render(:attendee, meeting.attendee_email, attendee_details)
    organizer = AppointmentConfirmation.render(:organizer, owner.email, organizer_details)

    for {email, details, place, label} <- [
          {attendee, attendee_details, "Gartenpavillon", "Firma"},
          {organizer, organizer_details, "Garden pavilion", "Company"}
        ] do
      assert details.email_sender == sender
      assert email.from == {sender.from_name, sender.from_address}

      for body <- [email.html_body, email.text_body] do
        assert body =~ place
        assert body =~ label
      end
    end

    ics = Enum.find(attendee.attachments, &String.starts_with?(&1.content_type, "text/calendar"))
    identity = ics_identity(ics.data)
    domain = Application.fetch_env!(:tymeslot, :email)[:domain]
    assert "UID:#{meeting.calendar_uid}@#{domain}" in identity
    assert "SEQUENCE:4" in identity
    assert Enum.any?(identity, &String.contains?(&1, "mailto:#{owner.email}"))
    assert ics.data =~ ~r/^LOCATION(?:;[^:]*)?:Gartenpavillon\r?$/m
    refute ics.data =~ sender.from_address
  end

  test "an explicit platform snapshot preserves its address and the traditional organizer display name" do
    sender = %Sender{
      sender()
      | kind: :platform,
        from_name: "Platform snapshot",
        from_address: "platform@snapshot.example"
    }

    email = MjmlEmail.base_email(sender: sender)
    assert email.from == {"Platform snapshot", "platform@snapshot.example"}

    email = MjmlEmail.from_organizer(email, "Organizer", sender)
    assert email.from == {"Organizer", "platform@snapshot.example"}
  end

  test "the organizer's meeting-end summary uses the booking sender" do
    meeting = build(:meeting, email_sender: sender())

    notice = %{
      previous_end_time: DateTime.add(meeting.end_time, -900, :second),
      attendees: [meeting.attendee_name],
      guests: 0
    }

    email =
      ExternalBookingChange.render_end_followed(
        meeting,
        meeting.organizer_email,
        notice,
        "Etc/UTC"
      )

    assert email.from == {"Customer bookings", "bookings@customer.example"}
    assert email.to == [{meeting.organizer_name, meeting.organizer_email}]
  end

  for discrepancy <- [:deleted, :modified] do
    test "the #{discrepancy} external calendar alert keeps the platform identity" do
      meeting = build(:meeting, email_sender: sender())

      email =
        ExternalBookingChange.render(
          meeting,
          meeting.organizer_email,
          unquote(discrepancy),
          "Etc/UTC"
        )

      assert email.from == MjmlEmail.base_email().from
      refute email.from == {"Customer bookings", "bookings@customer.example"}
    end
  end

  test "SMTP changes leave the ICS UID, organizer, sequence, and method unchanged" do
    details = details()
    custom = AppointmentConfirmation.render(:attendee, details.attendee_email, details)

    platform =
      AppointmentConfirmation.render(
        :attendee,
        details.attendee_email,
        Map.delete(details, :email_sender)
      )

    custom_ics = Enum.find(custom.attachments, &(&1.content_type =~ "text/calendar"))
    platform_ics = Enum.find(platform.attachments, &(&1.content_type =~ "text/calendar"))

    assert ics_identity(custom_ics.data) == ics_identity(platform_ics.data)
    assert custom_ics.data =~ "METHOD:PUBLISH"

    assert Enum.any?(
             ics_identity(custom_ics.data),
             &String.contains?(&1, details.organizer_email)
           )

    refute custom_ics.data =~ "bookings@customer.example"
  end

  defp details do
    build_appointment_details(%{
      email_sender: sender(),
      guest_name: "Guest",
      guest_accept_url: "https://example.com/guest/accept",
      guest_decline_url: "https://example.com/guest/decline",
      original_date: ~D[2026-01-14],
      original_start_time: ~U[2026-01-14 09:00:00Z],
      original_start_time_owner_tz: ~U[2026-01-14 09:00:00Z],
      original_start_time_attendee_tz: ~U[2026-01-14 09:00:00Z],
      original_end_time: ~U[2026-01-14 10:00:00Z]
    })
  end

  defp sender do
    %Sender{
      kind: :user_smtp,
      owner_id: 1,
      settings_id: 1,
      revision: 1,
      from_name: "Customer bookings",
      from_address: "bookings@customer.example"
    }
  end

  defp ics_identity(data) do
    data
    |> LineFolder.unfold_lines()
    |> Enum.filter(&String.starts_with?(&1, ["UID:", "ORGANIZER;", "SEQUENCE:", "METHOD:"]))
  end
end
