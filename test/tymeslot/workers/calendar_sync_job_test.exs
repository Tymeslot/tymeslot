defmodule Tymeslot.Workers.CalendarSyncJobTest do
  @moduledoc """
  The job boundary every calendar sync worker shares: which integration a
  cycle runs for, what a gone or undecryptable one ends as, and that a wait
  the bound cuts short reaches the health streak as the failure it is.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob

  setup do
    with_config(:tymeslot, :sync_failure_unhealthy_threshold, 3)
    :ok
  end

  defp job(integration_id, meta \\ %{}) do
    %Oban.Job{
      args: %{"calendar_integration_id" => integration_id},
      attempt: 1,
      meta: meta,
      worker: "Tymeslot.Workers.SyncCalDavCalendarWorker"
    }
  end

  defp failures(integration),
    do:
      Monitor.get_state(:calendar, integration.id, integration.user_id).consecutive_sync_failures

  defp waiting_cycle, do: fn _integration -> {:snooze, 120} end

  @bound [max_snoozes: 12, exhausted_reason: "Server did not recover"]

  test "runs the cycle with the integration the job names" do
    integration = insert(:calendar_integration, provider: "caldav")
    test_pid = self()

    assert :ok =
             CalendarSyncJob.run(job(integration.id), fn loaded ->
               send(test_pid, {:ran_for, loaded.id})
               :ok
             end)

    assert_received {:ran_for, id}
    assert id == integration.id
  end

  test "discards a job whose integration is gone, without running the cycle" do
    assert {:discard, "Integration not found"} =
             CalendarSyncJob.run(job(-1), fn _integration -> flunk("cycle ran") end)
  end

  test "flags an integration whose credentials no longer decrypt, without running the cycle" do
    integration =
      insert(:calendar_integration,
        provider: "caldav",
        needs_reauth: false,
        username_encrypted: :crypto.strong_rand_bytes(40),
        password_encrypted: :crypto.strong_rand_bytes(40)
      )

    assert {:discard, reason} =
             CalendarSyncJob.run(job(integration.id), fn _integration -> flunk("cycle ran") end)

    assert reason == ReauthHandling.discard_reason()

    assert {:error, :requires_reencryption, %{needs_reauth: true}} =
             CalendarIntegrationQueries.get(integration.id)
  end

  test "discards another provider's integration without touching its health" do
    integration = insert(:calendar_integration, provider: "google")

    assert {:discard, "Integration is not outlook"} =
             CalendarSyncJob.run(job(integration.id), fn _integration -> flunk("cycle ran") end,
               provider: "outlook"
             )

    assert failures(integration) == 0
  end

  # A cache write that finds its integration deleted answers
  # `{:error, :integration_gone}`; a provider that folds the reason into its
  # own failure shape (Outlook's transient/hard class) still fails once the
  # row is gone. Either way the job ends as one whose integration was gone at
  # the start does, and nothing is recorded against its health.
  describe "an integration deleted while its cycle runs" do
    setup do
      %{integration: insert(:calendar_integration, provider: "caldav")}
    end

    for {label, failure} <- [
          {"a cache write refused as gone", {:error, :integration_gone}},
          {"a failure of the provider's own shape", {:error, {:delta_sync_failed, :transient}}}
        ] do
      test "#{label} is discarded as not found", %{integration: integration} do
        assert {:discard, "Integration not found"} =
                 CalendarSyncJob.run(job(integration.id), fn loaded ->
                   Repo.delete!(loaded)
                   unquote(Macro.escape(failure))
                 end)

        assert failures(integration) == 0
      end
    end

    test "a failure while the integration still exists is recorded as one", %{
      integration: integration
    } do
      assert {:error, :timeout} =
               CalendarSyncJob.run(job(integration.id), fn _loaded -> {:error, :timeout} end)

      assert failures(integration) == 1
    end
  end

  describe "a cycle waiting out an unavailable provider" do
    setup do
      %{integration: insert(:calendar_integration, provider: "caldav")}
    end

    test "snoozes under the bound and leaves health alone", %{integration: integration} do
      assert {:snooze, 120} =
               CalendarSyncJob.run(
                 job(integration.id, %{"snoozed" => 10}),
                 waiting_cycle(),
                 @bound
               )

      assert failures(integration) == 0
    end

    test "fails at the bound, and the failure counts towards the streak",
         %{integration: integration} do
      assert {:error, "Server did not recover"} =
               CalendarSyncJob.run(
                 job(integration.id, %{"snoozed" => 11}),
                 waiting_cycle(),
                 @bound
               )

      assert failures(integration) == 1
    end

    test "is not bounded when the worker names no budget", %{integration: integration} do
      assert {:snooze, 120} =
               CalendarSyncJob.run(job(integration.id, %{"snoozed" => 500}), waiting_cycle())
    end
  end

  test "a failed cycle counts towards the streak and a completed one clears it" do
    integration = insert(:calendar_integration, provider: "caldav")

    assert {:error, :boom} =
             CalendarSyncJob.run(job(integration.id), fn _integration -> {:error, :boom} end)

    assert failures(integration) == 1

    assert :ok = CalendarSyncJob.run(job(integration.id), fn _integration -> :ok end)
    assert failures(integration) == 0
  end
end
