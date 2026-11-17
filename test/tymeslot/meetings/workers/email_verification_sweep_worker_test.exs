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
end
