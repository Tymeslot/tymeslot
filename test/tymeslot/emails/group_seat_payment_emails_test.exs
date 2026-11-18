defmodule Tymeslot.Emails.GroupSeatPaymentEmailsTest do
  @moduledoc """
  What a paid seat of a group meeting adds to its emails: the participant's
  receipt, the organiser's payout line, what the organiser is told when a
  paid spot is cancelled, and the organiser's seat count, which counts people
  and never the seats held for bookers still paying.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :payments

  import Tymeslot.Factory

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.Emails.Templates.SeatUpdateForOrganizer
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.Recipient

  setup do
    organizer = insert(:user, locale: "en", name: "Host")
    insert(:profile, user: organizer, timezone: "Europe/London")

    meeting =
      insert(:group_meeting,
        capacity: 6,
        organizer_user_id: organizer.id,
        organizer_email: "host@example.com",
        organizer_name: "Host",
        attendee_locale: "en",
        meeting_type: "Workshop"
      )

    %{organizer: organizer, meeting: meeting}
  end

  # A paid seat: a participant and the payment that took their seats. No
  # charge id, so building the receipt makes no Stripe call.
  defp paid_seat(ctx, name, attrs) do
    participant = insert(:participant, meeting: ctx.meeting, name: name, locale: "en")

    payment =
      insert(
        :paid_booking_payment,
        Keyword.merge(
          [
            meeting: ctx.meeting,
            participant: participant,
            seat_payment: true,
            seats: 1,
            amount_cents: 2000,
            application_fee_cents: 100,
            host_user_id: ctx.organizer.id,
            stripe_charge_id: nil
          ],
          attrs
        )
      )

    %{participant: participant, payment: payment, seat: Recipient.from_participant(participant)}
  end

  defp confirmation(ctx, seat, email),
    do:
      AppointmentConfirmation.render(
        :attendee,
        email,
        AppointmentBuilder.from_meeting(ctx.meeting, seat, nil)
      )

  describe "the participant's confirmation" do
    test "a paid seat's confirmation shows the amount and seat count", ctx do
      paid = paid_seat(ctx, "Ada", seats: 2, amount_cents: 4000)

      {:ok, [_guest]} =
        Guests.create_for_participant(ctx.meeting.id, paid.participant.id, ["guest@example.com"])

      email = confirmation(ctx, paid.seat, paid.participant.email)

      assert email.text_body =~ "PAYMENT RECEIPT"
      assert email.text_body =~ "€40.00 paid"
      assert email.text_body =~ "For 2 seats"
      assert email.html_body =~ "For 2 seats"
    end

    test "two paid seats on one meeting each get their own receipt", ctx do
      first = paid_seat(ctx, "Ada", amount_cents: 2000)
      second = paid_seat(ctx, "Grace", amount_cents: 6000, seats: 3)

      first_email = confirmation(ctx, first.seat, first.participant.email)
      second_email = confirmation(ctx, second.seat, second.participant.email)

      assert first_email.text_body =~ "€20.00 paid"
      refute first_email.text_body =~ "€60.00"
      refute first_email.text_body =~ "For 1 seat"
      assert second_email.text_body =~ "€60.00 paid"
      assert second_email.text_body =~ "For 3 seats"
      refute second_email.text_body =~ "€20.00"
    end

    test "a free group seat's emails carry no payment block", ctx do
      participant = insert(:participant, meeting: ctx.meeting, name: "Free", locale: "en")
      seat = Recipient.from_participant(participant)

      attendee = confirmation(ctx, seat, participant.email)

      organiser =
        SeatUpdateForOrganizer.render(
          :booked,
          "host@example.com",
          AppointmentBuilder.for_organizer_of_seat(ctx.meeting, seat)
        )

      for email <- [attendee, organiser] do
        refute email.text_body =~ "PAYMENT"
        refute email.html_body =~ "Payment receipt"
        refute email.html_body =~ "You received"
      end
    end
  end

  describe "the organiser's seat emails" do
    test "the organiser's spot-booked email shows the payout", ctx do
      paid = paid_seat(ctx, "Ada", seats: 2, amount_cents: 4000, application_fee_cents: 200)

      email =
        SeatUpdateForOrganizer.render(
          :booked,
          "host@example.com",
          AppointmentBuilder.for_organizer_of_seat(ctx.meeting, paid.seat)
        )

      assert email.text_body =~ "You received €38.00"
      assert email.text_body =~ "Attendee paid: €40.00"
      assert email.text_body =~ "For 2 seats"
      assert email.html_body =~ "You received"
    end

    test "the organiser hears a cancelled paid seat still holds money", ctx do
      paid = paid_seat(ctx, "Ada", amount_cents: 2000)

      details = AppointmentBuilder.for_organizer_of_seat(ctx.meeting, paid.seat)

      for details <- [details, Map.put(details, :slot_freed, true)] do
        email = SeatUpdateForOrganizer.render(:cancelled, "host@example.com", details)

        assert email.text_body =~ "REFUND OUTSTANDING:"
        assert email.text_body =~ "You still hold €20.00 for this booking."
        assert email.html_body =~ "Refund outstanding"
      end
    end

    test "a cancelled free seat says nothing about money", ctx do
      participant = insert(:participant, meeting: ctx.meeting, locale: "en")

      email =
        SeatUpdateForOrganizer.render(
          :cancelled,
          "host@example.com",
          AppointmentBuilder.for_organizer_of_seat(
            ctx.meeting,
            Recipient.from_participant(participant)
          )
        )

      refute email.text_body =~ "REFUND"
    end

    # A moved seat keeps its payment, so the move says nothing of money.
    test "the organiser's spot-moved email carries no payment block", ctx do
      paid = paid_seat(ctx, "Ada", amount_cents: 2000)

      details =
        ctx.meeting
        |> AppointmentBuilder.for_organizer_of_seat(paid.seat)
        |> Map.put(:original_start_time_owner_tz, ~U[2026-01-14 09:00:00Z])

      assert %{amount_cents: 2000} = details.booking_payment

      email = SeatUpdateForOrganizer.render(:moved, "host@example.com", details)

      for body <- [email.text_body, email.html_body] do
        refute body =~ "€20.00"
        refute body =~ "You received"
        refute String.downcase(body) =~ "refund"
      end
    end

    test "the organiser seat count ignores unpaid holds", ctx do
      paid = paid_seat(ctx, "Ada", amount_cents: 2000)
      insert(:seat_hold, meeting: ctx.meeting, seats: 2, email: "paying@example.com")

      details = AppointmentBuilder.for_organizer_of_seat(ctx.meeting, paid.seat)

      assert details.seats_taken == 1
    end
  end
end
