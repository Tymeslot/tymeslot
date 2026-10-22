defmodule Tymeslot.Workers.PollDeadlineRemindersTest do
  @moduledoc """
  The EmailWorker handler that sends a poll's deadline reminders: who it
  reaches, that a rescued job mails nobody twice, and when it discards.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :emails

  import Swoosh.TestAssertions
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.Workers.EmailWorker

  # Delivery runs inside the CircuitBreaker GenServer, so Swoosh's test adapter
  # would otherwise post {:email, _} to that process. Global mode routes it to
  # the test process instead; it requires `async: false`.
  setup :set_swoosh_global

  describe "send_poll_deadline_reminders" do
    test "delivers only to participants who have not voted" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "hostname")
      poll = insert(:poll, status: :open, user: user, deadline_at: in_hours(48))

      now = DateTime.utc_now(:second)

      unvoted =
        insert(:poll_participant,
          poll: poll,
          name: "Unvoted",
          email: "unvoted@example.com",
          invited_at: now,
          confirmed_at: now,
          link_sent_at: now,
          voted_at: nil
        )

      insert(:poll_participant,
        poll: poll,
        name: "Voted",
        email: "voted@example.com",
        voted_at: DateTime.utc_now(:second)
      )

      # Asked for a link but never confirmed it: not a participant yet.
      insert(:poll_participant,
        poll: poll,
        email: "unconfirmed@example.com",
        confirmed_at: nil,
        link_sent_at: DateTime.utc_now(:second)
      )

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => poll.id
               })

      assert_receive {:email, email}, 1000
      assert "unvoted@example.com" in recipients(email)
      # Their own link: voting is only possible through it.
      assert email.text_body =~ "/hostname/poll/#{poll.token}?p=#{unvoted.token}"
      refute_receive {:email, _other}, 200
    end

    test "a rescued job re-mails none of the participants it already reached" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "hostname")
      poll = insert(:poll, status: :open, user: user, deadline_at: in_hours(48))

      insert(:poll_participant,
        poll: poll,
        name: "First",
        email: "first@example.com",
        invited_at: DateTime.utc_now(:second),
        link_sent_at: DateTime.utc_now(:second),
        confirmed_at: DateTime.utc_now(:second)
      )

      insert(:poll_participant,
        poll: poll,
        name: "Second",
        email: "second@example.com",
        invited_at: DateTime.utc_now(:second),
        link_sent_at: DateTime.utc_now(:second),
        confirmed_at: DateTime.utc_now(:second)
      )

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_poll_deadline_reminders",
          "poll_id" => poll.id
        })

      assert :ok = EmailWorker.perform(job)
      assert :ok = EmailWorker.perform(job)

      assert_receive {:email, first}, 1000
      assert_receive {:email, second}, 1000
      refute_receive {:email, _duplicate}, 200

      assert Enum.sort(recipients(first) ++ recipients(second)) ==
               ["first@example.com", "second@example.com"]
    end

    test "shows the deadline in the poll's timezone to a participant with none" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "hostname")
      deadline = DateTime.add(DateTime.utc_now(:second), 2, :day)

      poll =
        insert(:poll, status: :open, user: user, deadline_at: deadline, timezone: "Asia/Tokyo")

      now = DateTime.utc_now(:second)

      insert(:poll_participant,
        poll: poll,
        email: "unvoted@example.com",
        timezone: nil,
        invited_at: now,
        confirmed_at: now,
        link_sent_at: now
      )

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => poll.id
               })

      assert_receive {:email, email}, 1000

      expected =
        deadline
        |> DateTimeUtils.convert_to_timezone("Asia/Tokyo")
        |> Formatting.format_datetime("en")

      assert email.text_body =~ expected
    end

    test "discards when the poll is not open" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      poll = insert(:poll, status: :confirmed, user: user)

      assert {:discard, "poll not open"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => poll.id
               })
    end

    test "discards without delivering when the host has no username" do
      # No profile inserted for the host, so host_username/1 resolves to nil and
      # the public voting URL would be broken.
      user = insert(:user)
      poll = insert(:poll, status: :open, user: user, deadline_at: in_hours(48))

      insert(:poll_participant,
        poll: poll,
        name: "Unvoted",
        email: "unvoted@example.com",
        invited_at: DateTime.utc_now(:second),
        link_sent_at: DateTime.utc_now(:second),
        confirmed_at: DateTime.utc_now(:second)
      )

      assert {:discard, "host has no username"} =
               perform_job(EmailWorker, %{
                 "action" => "send_poll_deadline_reminders",
                 "poll_id" => poll.id
               })

      refute_receive {:email, _any}, 200
    end
  end

  defp in_hours(hours) do
    DateTime.utc_now() |> DateTime.add(hours * 3600, :second) |> DateTime.truncate(:second)
  end

  defp recipients(email), do: Enum.map(email.to, fn {_name, address} -> address end)
end
