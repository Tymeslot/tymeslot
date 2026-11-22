defmodule Tymeslot.Meetings.Workers.EmailVerificationSweepWorkerTest do
  @moduledoc """
  The cron backstop for unverified bookings whose expiry job never fired: it
  releases every due booking, leaves verified ones alone, and one failure
  does not stop the rest.
  """

  # async: false: the failing release is simulated by patching
  # EmailVerification.expire/1 with :meck, which is global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Workers.EmailVerificationSweepWorker

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp past, do: DateTime.add(DateTime.utc_now(:second), -5, :minute)

  test "expires the due bookings and leaves the rest" do
    due =
      for _n <- 1..2, do: insert(:awaiting_verification_meeting, verification_deadline_at: past())

    still_held = insert(:awaiting_verification_meeting)

    verified =
      insert(:awaiting_verification_meeting,
        status: :confirmed,
        email_verified_at: past(),
        verification_deadline_at: past()
      )

    assert {:ok, %{expired: 2, skipped: 0, failed: 0}} =
             perform_job(EmailVerificationSweepWorker, %{})

    assert Enum.map(due, &reload(&1).status) == [:expired, :expired]
    assert reload(still_held).status == :awaiting_verification
    assert reload(verified).status == :confirmed
  end

  test "dates a booking it reaches long after its deadline to the deadline" do
    deadline = DateTime.add(DateTime.utc_now(:second), -30, :day)
    overdue = insert(:awaiting_verification_meeting, verification_deadline_at: deadline)

    assert {:ok, %{expired: 1}} = perform_job(EmailVerificationSweepWorker, %{})

    assert reload(overdue).status == :expired
    assert DateTime.compare(reload(overdue).cancelled_at, deadline) == :eq
  end

  test "a release that raises is counted as failed and the others still run" do
    [failing, other] =
      for _n <- 1..2, do: insert(:awaiting_verification_meeting, verification_deadline_at: past())

    failing_id = failing.id
    :meck.new(EmailVerification, [:passthrough])

    :meck.expect(EmailVerification, :expire, fn
      %{id: ^failing_id} -> raise "boom"
      meeting -> :meck.passthrough([meeting])
    end)

    try do
      assert {:ok, %{expired: 1, skipped: 0, failed: 1}} =
               perform_job(EmailVerificationSweepWorker, %{})
    after
      :meck.unload(EmailVerification)
    end

    assert reload(failing).status == :awaiting_verification
    assert reload(other).status == :expired
  end

  test "expires the due group seats and leaves the rest" do
    slot = insert(:group_meeting)
    due = insert(:participant, meeting: slot, verification_deadline_at: past())

    still_held =
      insert(:participant,
        meeting: slot,
        verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)
      )

    verified =
      insert(:participant,
        meeting: slot,
        verification_deadline_at: past(),
        email_verified_at: past()
      )

    assert {:ok, %{expired: 1, skipped: 0, failed: 0}} =
             perform_job(EmailVerificationSweepWorker, %{})

    assert %{cancelled_at: %DateTime{}} = Repo.get!(ParticipantSchema, due.id)
    assert Repo.get!(ParticipantSchema, still_held.id).cancelled_at == nil
    assert Repo.get!(ParticipantSchema, verified.id).cancelled_at == nil
    assert reload(slot).status == :confirmed
  end

  test "a seat release that raises is counted as failed" do
    seat = insert(:participant, meeting: insert(:group_meeting), verification_deadline_at: past())

    :meck.new(EmailVerification, [:passthrough])
    :meck.expect(EmailVerification, :expire_seat, fn _seat -> raise "boom" end)

    try do
      assert {:ok, %{expired: 0, skipped: 0, failed: 1}} =
               perform_job(EmailVerificationSweepWorker, %{})
    after
      :meck.unload(EmailVerification)
    end

    assert Repo.get!(ParticipantSchema, seat.id).cancelled_at == nil
  end
end
