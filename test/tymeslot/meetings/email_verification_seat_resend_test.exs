defmodule Tymeslot.Meetings.EmailVerificationSeatResendTest do
  @moduledoc """
  Resending a held seat's verification email: what is sent and counted, the
  cap, and the seats and slots that refuse a resend.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.SeatVerificationHelpers

  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Workers.EmailWorker

  setup :context

  describe "resend_seat/1" do
    test "resending a seat's email sends the seat email and keeps the deadline", ctx do
      slot = slot(ctx, :awaiting_verification)
      seat = held_seat(slot, "first@example.com")

      assert {:ok, %ParticipantSchema{verification_emails_sent: 2}} =
               EmailVerification.resend_seat(seat)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_seat_email_verification",
          "meeting_id" => slot.id,
          "participant_id" => seat.id,
          "send" => 2
        }
      )

      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_booking_email_verification"})

      assert %{verification_deadline_at: deadline, verification_emails_sent: 2} = reload(seat)
      assert deadline == seat.verification_deadline_at
      assert reload(slot).verification_emails_sent == nil
    end

    test "seat resends stop at the cap", ctx do
      seat = ctx |> slot(:awaiting_verification) |> held_seat("first@example.com")

      for send <- 2..4 do
        assert {:ok, %{verification_emails_sent: ^send}} = EmailVerification.resend_seat(seat)
      end

      assert {:error, :limit_reached} = EmailVerification.resend_seat(seat)
      assert reload(seat).verification_emails_sent == 4
      assert length(all_enqueued(worker: EmailWorker)) == 3
    end

    test "a seat cannot be resent once verified, released or lapsed", ctx do
      slot = slot(ctx, :confirmed)

      verified =
        held_seat(slot, "verified@example.com", nil, email_verified_at: DateTime.utc_now(:second))

      released = held_seat(slot, "released@example.com")
      {:ok, _released} = EmailVerification.release_seat(released)

      lapsed =
        held_seat(slot, "lapsed@example.com", DateTime.add(DateTime.utc_now(:second), -60))

      assert {:error, :not_awaiting_verification} = EmailVerification.resend_seat(verified)
      assert {:error, :not_awaiting_verification} = EmailVerification.resend_seat(released)
      assert {:error, :expired} = EmailVerification.resend_seat(lapsed)
      assert %{cancelled_at: %DateTime{}} = reload(lapsed)

      assert all_enqueued(worker: EmailWorker) == []
    end

    # Its job would be discarded on a slot whose time does not hold, so a
    # resend counted then would use one up and send nothing.
    test "a seat on a slot awaiting a new time is refused before anything is counted", ctx do
      slot = slot(ctx, :confirmed, reschedule_requested_at: DateTime.utc_now(:second))
      visible_seat(slot, "first@example.com")
      seat = held_seat(slot, "second@example.com")

      assert {:error, :slot_void} = EmailVerification.resend_seat(seat)
      assert %{verification_emails_sent: nil, cancelled_at: nil} = reload(seat)
      assert all_enqueued(worker: EmailWorker) == []

      slot |> reload() |> Changeset.change(reschedule_requested_at: nil) |> Repo.update!()

      assert {:ok, %{verification_emails_sent: 2}} = EmailVerification.resend_seat(seat)
    end

    test "a lapsed seat on a slot awaiting a new time is released, not kept waiting", ctx do
      slot = slot(ctx, :confirmed, reschedule_requested_at: DateTime.utc_now(:second))
      visible_seat(slot, "first@example.com")
      seat = held_seat(slot, "second@example.com", DateTime.add(DateTime.utc_now(:second), -60))

      assert {:error, :expired} = EmailVerification.resend_seat(seat)
      assert %{cancelled_at: %DateTime{}} = reload(seat)
    end

    test "a group slot's own email is never resent", ctx do
      slot = slot(ctx, :awaiting_verification)
      held_seat(slot, "first@example.com")

      assert {:error, :not_awaiting_verification} = EmailVerification.resend(slot)
      assert reload(slot).verification_emails_sent == nil
      assert all_enqueued(worker: EmailWorker) == []
    end
  end
end
