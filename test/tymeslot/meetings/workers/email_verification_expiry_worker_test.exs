defmodule Tymeslot.Meetings.Workers.EmailVerificationExpiryWorkerTest do
  @moduledoc """
  The punctual release of an unverified booking at its deadline, and the
  stale jobs it must leave alone.
  """

  # async: false: the race case patches EmailVerification with :meck, which
  # is global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :meetings

  alias Ecto.UUID
  alias Oban.Job
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.EmailVerificationJobs
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp args(meeting), do: %{"meeting_id" => meeting.id}

  test "scheduling places the job at the deadline" do
    meeting = insert(:awaiting_verification_meeting)

    assert :ok = EmailVerificationJobs.schedule_expiry(meeting)

    job = Repo.get_by!(Job, worker: "Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker")
    assert DateTime.compare(job.scheduled_at, meeting.verification_deadline_at) == :eq
  end

  test "a held booking past its deadline is expired" do
    meeting =
      insert(:awaiting_verification_meeting,
        verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60)
      )

    assert :ok = perform_job(EmailVerificationExpiryWorker, args(meeting))
    assert reload(meeting).status == :expired
  end

  test "a verified booking is left alone" do
    meeting =
      insert(:awaiting_verification_meeting,
        status: :confirmed,
        email_verified_at: DateTime.utc_now(:second),
        verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60)
      )

    assert {:discard, reason} = perform_job(EmailVerificationExpiryWorker, args(meeting))
    assert EmailVerificationExpiryWorker.expected_outcome?(reason)
    assert reload(meeting).status == :confirmed
  end

  test "a job running before the deadline does nothing" do
    meeting = insert(:awaiting_verification_meeting)

    assert {:discard, "Verification not due yet: " <> _deadline} =
             perform_job(EmailVerificationExpiryWorker, args(meeting))

    assert reload(meeting).status == :awaiting_verification
  end

  test "a booking verified while the job expires it is an expected discard" do
    meeting =
      insert(:awaiting_verification_meeting,
        verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60)
      )

    # The other exit lands between the job's read and its expiry.
    :meck.new(EmailVerification, [:passthrough])

    :meck.expect(EmailVerification, :expire, fn held ->
      {:ok, _released} = EmailVerification.release(held)
      :meck.passthrough([held])
    end)

    try do
      assert {:discard, reason} = perform_job(EmailVerificationExpiryWorker, args(meeting))
      assert EmailVerificationExpiryWorker.expected_outcome?(reason)
    after
      :meck.unload(EmailVerification)
    end

    assert reload(meeting).status == :cancelled
  end

  test "a deleted meeting is an expected discard" do
    assert {:discard, reason} =
             perform_job(EmailVerificationExpiryWorker, %{"meeting_id" => UUID.generate()})

    assert EmailVerificationExpiryWorker.expected_outcome?(reason)
  end

  test "a booking with no deadline gets no job" do
    meeting = insert(:meeting)

    assert :ok = EmailVerificationJobs.schedule_expiry(meeting)
    refute_enqueued(worker: EmailVerificationExpiryWorker)
  end

  test "cancelling removes the job" do
    type = insert(:meeting_type)

    meeting =
      insert(:awaiting_verification_meeting,
        organizer_user_id: type.user_id,
        meeting_type_id: type.id
      )

    :ok = EmailVerificationJobs.schedule_expiry(meeting)

    {:ok, :verified, _verified} = EmailVerification.verify(meeting)

    refute_enqueued(worker: EmailVerificationExpiryWorker)
  end
end
