defmodule Tymeslot.Meetings.Workers.EmailVerificationExpiryWorkerTest do
  @moduledoc """
  The punctual release of an unverified booking at its deadline, and the
  stale jobs it must leave alone.
  """

  use Tymeslot.DataCase, async: true
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

  test "a deleted meeting is an expected discard" do
    assert {:discard, reason} =
             perform_job(EmailVerificationExpiryWorker, %{"meeting_id" => UUID.generate()})

    assert EmailVerificationExpiryWorker.expected_outcome?(reason)
  end

  test "cancelling removes the job" do
    meeting = insert(:awaiting_verification_meeting)
    :ok = EmailVerificationJobs.schedule_expiry(meeting)

    {:ok, :verified, _verified} = EmailVerification.verify(meeting)

    refute_enqueued(worker: EmailVerificationExpiryWorker)
  end
end
