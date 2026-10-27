defmodule Tymeslot.Workers.PollEmailPartialFailureTest do
  @moduledoc """
  A poll email to several recipients reports a failed delivery, so the job is
  retried, and the retry writes only to whoever was not reached. Runs the real
  delivery through an adapter that fails for chosen addresses.
  """

  # async: false: the mailer adapter, its errors and the email circuit
  # breaker are global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :emails

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.EmailWorker

  setup do
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
    setup_config(:tymeslot, :test_delivery_attempts_to, self())

    setup_config(:tymeslot, :test_delivery_error, %{
      "bob@example.com" => :econnrefused,
      default: :ok
    })

    breaker = CircuitBreakerSupervisor.email_breaker_name()
    CircuitBreaker.reset(breaker)
    on_exit(fn -> CircuitBreaker.reset(breaker) end)

    user = insert(:user)
    _profile = insert(:profile, user: user, username: "hostname")
    %{user: user}
  end

  describe "deadline reminders" do
    test "fail the job when one delivery fails, and a rerun mails only that recipient", ctx do
      poll =
        insert(:poll,
          status: :open,
          user: ctx.user,
          deadline_at: DateTime.add(DateTime.utc_now(:second), 2, :day)
        )

      invitee(poll, "ada@example.com")
      invitee(poll, "bob@example.com")

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_poll_deadline_reminders",
          "poll_id" => poll.id
        })

      assert_failed_then_rerun_reaches_only_bob(job)
    end
  end

  describe "new times" do
    test "fail the job when one delivery fails, and a rerun mails only that recipient", ctx do
      poll = insert(:poll, status: :open, user: ctx.user)
      slot = insert(:poll_time_slot, poll: poll, start_time: ~U[2030-03-04 10:00:00Z])
      invitee(poll, "ada@example.com", voted_at: DateTime.utc_now(:second))
      invitee(poll, "bob@example.com", voted_at: DateTime.utc_now(:second))

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_poll_new_times",
          "poll_id" => poll.id,
          "slot_ids" => [slot.id]
        })

      assert_failed_then_rerun_reaches_only_bob(job)
    end
  end

  describe "cancellation" do
    test "fails the job when one delivery fails, and a rerun mails only that recipient", ctx do
      poll = insert(:poll, status: :cancelled, user: ctx.user)
      invitee(poll, "ada@example.com")
      invitee(poll, "bob@example.com")

      job =
        persisted_job(EmailWorker, %{"action" => "send_poll_cancelled", "poll_id" => poll.id})

      assert_failed_then_rerun_reaches_only_bob(job)
    end

    test "fails the job too when the recipients ride on the job", ctx do
      recipients =
        for email <- ["ada@example.com", "bob@example.com"],
            do: %{
              "id" => UUID.generate(),
              "name" => email,
              "email" => email,
              "locale" => "en"
            }

      job =
        persisted_job(EmailWorker, %{
          "action" => "send_poll_cancelled",
          "poll_id" => UUID.generate(),
          "user_id" => ctx.user.id,
          "title" => "Team sync",
          "recipients" => recipients
        })

      assert_failed_then_rerun_reaches_only_bob(job)
    end
  end

  defp assert_failed_then_rerun_reaches_only_bob(job) do
    assert {:error, _reason} = quietly(fn -> EmailWorker.perform(job) end)
    assert attempts() == ["ada@example.com", "bob@example.com"]

    setup_config(:tymeslot, :test_delivery_error, %{default: :ok})
    CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name())

    assert :ok = quietly(fn -> EmailWorker.perform(job) end)
    assert attempts() == ["bob@example.com"]
  end

  defp attempts do
    receive do
      {:delivery_attempt, [address]} -> [address | attempts()]
    after
      0 -> []
    end
    |> Enum.sort()
  end

  defp invitee(poll, email, attrs \\ []) do
    now = DateTime.utc_now(:second)

    insert(
      :poll_participant,
      Keyword.merge(
        [poll: poll, email: email, invited_at: now, confirmed_at: now, link_sent_at: now],
        attrs
      )
    )
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
