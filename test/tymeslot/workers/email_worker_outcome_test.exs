defmodule Tymeslot.Workers.EmailWorkerOutcomeTest do
  @moduledoc """
  What `EmailWorker` hands Oban for a handler's result it has no special
  rule for: the reason as it came, redacted, so the job's recorded error
  says what went wrong without naming the recipient.

  The failures are real ones: the email is built by the real email service
  and refused by `Tymeslot.Test.FailingMailerAdapter`, and the
  lapsed-reschedule notice is the job, since its handler hands the delivery
  reason on as it came.
  """

  # async: false: the mailer adapter, the email service and the email circuit
  # breaker are global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.EmailWorker

  setup do
    setup_config(:tymeslot, :email_service_module, EmailService)
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)

    breaker = CircuitBreakerSupervisor.email_breaker_name()
    CircuitBreaker.reset(breaker)
    on_exit(fn -> CircuitBreaker.reset(breaker) end)

    host = insert(:user, email: "jane@example.com")

    meeting =
      insert(:meeting,
        organizer_user: host,
        organizer_user_id: host.id,
        status: "expired",
        first_announced_at: DateTime.utc_now(:second)
      )

    %{meeting: meeting}
  end

  test "an error reason with no rule of its own is kept, not replaced by \"Unknown error\"",
       %{meeting: meeting} do
    setup_config(:tymeslot, :test_delivery_error, {:http_error, 500, "provider down"})

    assert {:error, reason} = perform_lapsed_notice(meeting)
    assert reason == ~s({:http_error, 500, "provider down"})
  end

  # Recorded on the job, so an address in a provider's error body is masked.
  test "an address inside the reason is masked before it is recorded", %{meeting: meeting} do
    setup_config(
      :tymeslot,
      :test_delivery_error,
      {422, %{"Message" => "Invalid 'To' address: jane@example.com"}}
    )

    assert {:error, reason} = perform_lapsed_notice(meeting)

    assert reason =~ "422"
    assert reason =~ "Invalid 'To' address"
    refute reason =~ "jane@example.com"
  end

  test "a result outside the handler contract is kept inside the error" do
    # Patched with :meck: every real handler maps its outcome onto the
    # contract, so no real job can return a result outside it.
    :meck.new(EmailHandlers, [:passthrough])
    on_exit(fn -> :meck.unload() end)

    :meck.expect(EmailHandlers, :execute_email_action, fn _action, _args, _job_id ->
      {:ok, :sent}
    end)

    assert {:error, "Unexpected result: {:ok, :sent}"} =
             EmailWorker.perform(%Oban.Job{
               id: System.unique_integer([:positive]),
               attempt: 1,
               args: %{"action" => "send_no_password_to_reset", "user_id" => 1}
             })
  end

  defp perform_lapsed_notice(meeting) do
    perform_job(EmailWorker, %{
      "action" => "send_reschedule_request_expired",
      "meeting_id" => meeting.id
    })
  end
end
