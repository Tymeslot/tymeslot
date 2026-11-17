defmodule Tymeslot.Workers.BookingVerificationEmailTest do
  @moduledoc """
  The verification email job: it sends once per send, only for a booking that
  is still held and in time, and a resend is a send of its own.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :bookings

  import Mox
  import Tymeslot.WorkerTestHelpers, only: [persisted_job: 2]

  alias Tymeslot.Emails.EmailScheduler.MeetingScheduler
  alias Tymeslot.Meetings.EmailVerificationToken
  alias Tymeslot.Workers.EmailWorker

  setup :set_mox_from_context

  setup do
    stub_with(Tymeslot.EmailServiceMock, Tymeslot.Emails.EmailService)
    previous = Application.get_env(:swoosh, :shared_test_process)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:swoosh, :shared_test_process, previous),
        else: Application.delete_env(:swoosh, :shared_test_process)
    end)

    :ok
  end

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: :awaiting_verification,
      organizer_user: user,
      organizer_user_id: user.id,
      verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 20, :minute)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  defp args(meeting, extra) do
    Map.merge(
      %{"action" => "send_booking_email_verification", "meeting_id" => meeting.id},
      extra
    )
  end

  defp perform(meeting, extra \\ %{}), do: perform_job(EmailWorker, args(meeting, extra))

  # One persisted job run twice, as the Oban lifeline does after a rescue.
  defp job(meeting, extra \\ %{}), do: persisted_job(EmailWorker, args(meeting, extra))

  test "a held booking gets its verification email once" do
    meeting = held_meeting()

    job = job(meeting)

    assert :ok = EmailWorker.perform(job)
    assert_received {:email, email}
    assert email.to == [{meeting.attendee_name, meeting.attendee_email}]

    token = email.text_body |> String.split("/verify-booking/") |> List.last() |> String.trim()
    token = token |> String.split(~r/\s/) |> hd()
    assert {:ok, verified} = EmailVerificationToken.verify(token)
    assert verified.id == meeting.id

    assert :ok = EmailWorker.perform(job)
    refute_received {:email, _email}
  end

  test "a resend is its own send, a retry of the same send is not" do
    meeting = held_meeting()

    first = job(meeting, %{"send" => 1})
    resend = job(meeting, %{"send" => 2})

    assert :ok = EmailWorker.perform(first)
    assert :ok = EmailWorker.perform(resend)
    assert :ok = EmailWorker.perform(first)
    assert_received {:email, _email}
    assert_received {:email, _email}
    refute_received {:email, _email}
  end

  test "a booking verified or expired before the job ran gets no email" do
    for status <- [:confirmed, :expired] do
      meeting = held_meeting(%{status: status})
      assert {:discard, _reason} = perform(meeting)
    end

    refute_received {:email, _email}
  end

  test "a booking past its deadline gets no email" do
    meeting =
      held_meeting(%{verification_deadline_at: DateTime.add(DateTime.utc_now(:second), -60)})

    assert {:discard, _reason} = perform(meeting)
    refute_received {:email, _email}
  end

  describe "schedule_verification_email/2" do
    test "scheduling twice within five minutes inserts one job" do
      meeting = held_meeting()

      assert :ok = MeetingScheduler.schedule_verification_email(meeting.id)
      assert :ok = MeetingScheduler.schedule_verification_email(meeting.id)

      assert [job] = all_enqueued(worker: EmailWorker)

      assert job.args == %{
               "action" => "send_booking_email_verification",
               "meeting_id" => meeting.id,
               "send" => 1
             }
    end

    test "a resend with the next send number is not swallowed" do
      meeting = held_meeting()

      assert :ok = MeetingScheduler.schedule_verification_email(meeting.id)
      assert :ok = MeetingScheduler.schedule_verification_email(meeting.id, 2)
      assert :ok = MeetingScheduler.schedule_verification_email(meeting.id, 2)

      sends = all_enqueued(worker: EmailWorker) |> Enum.map(& &1.args["send"]) |> Enum.sort()
      assert sends == [1, 2]
    end
  end
end
