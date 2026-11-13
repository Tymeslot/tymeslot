defmodule Tymeslot.Meetings.EmailVerificationTest do
  @moduledoc """
  The pure parts of the email verification gate: which meeting types it
  applies to, how long a booking is held, and the attributes a held booking
  is created with.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :meetings

  alias Tymeslot.Meetings.EmailVerification

  describe "required?/1" do
    test "reads the type" do
      assert EmailVerification.required?(%{requires_email_verification: true})
      refute EmailVerification.required?(%{requires_email_verification: false})
      refute EmailVerification.required?(nil)
    end
  end

  describe "deadline_for/2" do
    test "the hold is 30 minutes" do
      assert EmailVerification.deadline_for(~U[2026-11-12 10:00:00Z], ~U[2026-11-13 10:00:00Z]) ==
               ~U[2026-11-12 10:30:00Z]
    end

    test "the hold never outlasts the meeting's start" do
      assert EmailVerification.deadline_for(~U[2026-11-12 10:00:00Z], ~U[2026-11-12 10:10:00Z]) ==
               ~U[2026-11-12 10:10:00Z]
    end
  end

  describe "gate_attributes/2" do
    test "gate attributes leave approval unstamped" do
      now = ~U[2026-11-12 10:00:00Z]

      assert EmailVerification.gate_attributes(now, ~U[2026-11-13 10:00:00Z]) == %{
               status: :awaiting_verification,
               verification_deadline_at: ~U[2026-11-12 10:30:00Z],
               approval_requested_at: nil,
               approval_deadline_at: nil
             }
    end
  end
end
