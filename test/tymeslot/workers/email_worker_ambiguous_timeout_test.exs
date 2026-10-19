defmodule Tymeslot.Workers.EmailWorkerAmbiguousTimeoutTest do
  @moduledoc """
  A send that timed out after the message may have been handed over is
  retried once, and never again: the job records the retry, and its next run
  assumes such a send delivered. A copy kept as sent, or assumed sent, never
  goes out again. Runs the real email service through a failing adapter, so
  every attempt counted reached the provider.
  """

  # async: false: the mailer adapter, its error and the email service are
  # global configuration, and the email circuit breaker is shared.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  @moduletag :emails

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.EmailWorker

  setup do
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
    setup_config(:tymeslot, :test_delivery_error, :timeout)
    setup_config(:tymeslot, :test_delivery_attempts_to, self())
    setup_config(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    breaker = CircuitBreakerSupervisor.email_breaker_name()
    CircuitBreaker.reset(breaker)
    on_exit(fn -> CircuitBreaker.reset(breaker) end)
    :ok
  end

  test "a single email is retried once after an ambiguous timeout, then assumed sent" do
    user = insert(:user)
    job = insert_job(%{"action" => "send_no_password_to_reset", "user_id" => user.id})

    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _to}

    assert :ok = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _to}
    refute_received {:delivery_attempt, _more}
  end

  test "each claimed copy is retried once, and never sent again once assumed sent" do
    meeting = insert(:meeting, status: "cancelled")
    job = insert_job(%{"action" => "send_cancellation_emails", "meeting_id" => meeting.id})

    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _organizer}
    assert_received {:delivery_attempt, _attendee}

    assert :ok = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _organizer}
    assert_received {:delivery_attempt, _attendee}

    # Whatever happens after, the copies assumed sent are claimed.
    setup_config(:tymeslot, :test_delivery_error, :econnrefused)
    assert :ok = quietly(fn -> run(job) end)
    refute_received {:delivery_attempt, _more}
  end

  # The retry is recorded as the timeout happens, not when the run returns,
  # so a later copy crashing the run cannot let the first copy go out again
  # on every attempt.
  test "a run that crashes after an ambiguous timeout still spends that copy's one retry" do
    meeting = insert(:meeting, status: "cancelled")

    setup_config(:tymeslot, :test_delivery_error, %{
      meeting.organizer_email => :timeout,
      meeting.attendee_email => :exit
    })

    job = insert_job(%{"action" => "send_cancellation_emails", "meeting_id" => meeting.id})

    for _run <- 1..3, do: quietly(fn -> run(job) end)

    assert attempts_to(meeting.organizer_email) == 2
  end

  # The record is per job. Another copy's ordinary failure keeps retrying as
  # it would anyway, while the copy that timed out is retried once.
  test "a copy failing for an ordinary reason keeps retrying alongside one that timed out" do
    meeting = insert(:meeting, status: "cancelled")

    setup_config(:tymeslot, :test_delivery_error, %{
      meeting.organizer_email => :timeout,
      meeting.attendee_email => :econnrefused
    })

    job = insert_job(%{"action" => "send_cancellation_emails", "meeting_id" => meeting.id})

    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert {:error, _reason} = quietly(fn -> run(job) end)

    assert attempts_to(meeting.organizer_email) == 2
    assert attempts_to(meeting.attendee_email) == 3
  end

  # The documented cost of a per-job record: once one copy has had its retry,
  # another copy's first ambiguous timeout in the same job gets none.
  test "a second copy's first ambiguous timeout in the same job is assumed sent without a retry" do
    meeting = insert(:meeting, status: "cancelled")

    setup_config(:tymeslot, :test_delivery_error, %{
      meeting.organizer_email => :timeout,
      meeting.attendee_email => :econnrefused
    })

    job = insert_job(%{"action" => "send_cancellation_emails", "meeting_id" => meeting.id})
    assert {:error, _reason} = quietly(fn -> run(job) end)

    # Run 2: the organiser's copy is assumed sent; the attendee's times out
    # ambiguously for the first time, and is assumed sent too.
    setup_config(:tymeslot, :test_delivery_error, :timeout)
    assert :ok = quietly(fn -> run(job) end)
    assert :ok = quietly(fn -> run(job) end)

    assert attempts_to(meeting.attendee_email) == 2
  end

  # Only an ambiguous timeout spends the one retry; an ordinary failure
  # retries as before, and a later ambiguous timeout still gets its retry.
  test "an ordinary failure does not spend the retry an ambiguous timeout gets" do
    user = insert(:user)
    job = insert_job(%{"action" => "send_no_password_to_reset", "user_id" => user.id})

    setup_config(:tymeslot, :test_delivery_error, :econnrefused)
    assert {:error, _reason} = quietly(fn -> run(job) end)

    setup_config(:tymeslot, :test_delivery_error, :timeout)
    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert :ok = quietly(fn -> run(job) end)
  end

  defp attempts_to(address) do
    receive do
      {:delivery_attempt, [^address]} -> 1 + attempts_to(address)
    after
      0 -> 0
    end
  end

  defp insert_job(args) do
    {:ok, job} = args |> EmailWorker.new() |> Oban.insert()
    job
  end

  # Each timeout counts against the email circuit breaker; a run here stands
  # for a retry minutes later, once it has recovered.
  defp run(job) do
    CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name())
    EmailWorker.perform(%{job | attempt: job.attempt + 1})
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
