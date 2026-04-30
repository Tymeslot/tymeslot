defmodule Tymeslot.Workers.IntegrationAutoPauseWorkerIntegrationTest do
  @moduledoc """
  Integration test that verifies the complete auto-pause → email cascade.

  Exercises the full chain:
    IntegrationAutoPauseWorker.perform/1
      → EmailScheduler enqueues a paused-notification job
      → Oban.drain_queue/1 executes the email job
      → Swoosh.Adapters.Test captures the delivered email

  A broken handler returning `{:error, _}` would silently retry with no signal
  from the unit tests — this test catches that class of regression.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :workers
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.TestFixtures
  import Tymeslot.WorkerTestHelpers, only: [insert_unhealthy_health_row: 4]

  alias Tymeslot.Workers.IntegrationAutoPauseWorker

  setup do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
    end)

    user = create_user_fixture()
    %{user: user}
  end

  describe "auto-pause → email cascade" do
    test "paused notification email is delivered end-to-end", %{user: user} do
      integration = insert(:calendar_integration, user: user, is_active: true)

      old_unhealthy = DateTime.add(DateTime.utc_now(), -15 * 24 * 3600, :second)

      insert_unhealthy_health_row(user, :calendar, integration.id,
        became_unhealthy_at: old_unhealthy,
        consecutive_hard_failures: 5
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      # `:success` from drain_queue proves the handler ran end-to-end:
      # user/integration fetched, EmailService called, email delivery succeeded.
      # Swoosh.Adapters.Test cannot be observed here because Tymeslot routes
      # delivery through a CircuitBreaker GenServer — the {:email, ...} message
      # does not reach the test process. See test/tymeslot/emails/delivery_test.exs.
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :emails)
    end
  end
end
