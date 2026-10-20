defmodule Tymeslot.Integrations.Calendar.SyncScheduleTest do
  @moduledoc """
  The one table that says, per provider, which worker syncs it, how often the
  sweep starts a sync, when the grid calls its events stale, and how an
  owner's request for a sync is made.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.SyncSchedule
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncDebugCalendarWorker
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  @now ~U[2026-10-09 12:00:00Z]

  defp synced(provider, minutes_ago, attrs \\ []) do
    struct!(
      CalendarIntegrationSchema,
      Keyword.merge(
        [provider: provider, last_external_sync_at: DateTime.add(@now, -minutes_ago, :minute)],
        attrs
      )
    )
  end

  for {provider, worker} <- [
        {"google", SyncGoogleCalendarWorker},
        {"outlook", RefreshOutlookCalendarWorker},
        {"ics_url", SyncIcsCalendarWorker},
        {"exchange", SyncExchangeCalendarWorker},
        {"debug", SyncDebugCalendarWorker},
        {"caldav", SyncCalDavCalendarWorker},
        {"nextcloud", SyncCalDavCalendarWorker},
        {"radicale", SyncCalDavCalendarWorker}
      ] do
    test "#{provider} syncs with #{inspect(worker)}" do
      assert {:ok, %{worker: unquote(worker)}} =
               SyncSchedule.schedule(%CalendarIntegrationSchema{provider: unquote(provider)})
    end
  end

  # A sync is short provider I/O, so every swept provider's runs on the
  # wide `:calendar_events` queue; the two-slot `:calendar_integrations`
  # queue is for health checks and the sweep itself.
  for provider <- ["google", "outlook", "ics_url", "exchange", "caldav"] do
    test "a #{provider} sync runs on the calendar_events queue" do
      {:ok, %{worker: worker}} =
        SyncSchedule.schedule(%CalendarIntegrationSchema{provider: unquote(provider)})

      assert worker.new(%{"calendar_integration_id" => 1}).changes.queue == "calendar_events"
    end
  end

  describe "a provider with no schedule" do
    setup do
      %{integration: %CalendarIntegrationSchema{id: 1, provider: "carrier_pigeon"}}
    end

    test "is refused rather than handed to a default worker", %{integration: integration} do
      assert {:error, :unsupported_provider} = SyncSchedule.schedule(integration)
      assert {:error, :unsupported_provider} = SyncSchedule.request_sync(integration)
    end

    test "is never due and never stale", %{integration: integration} do
      refute SyncSchedule.due?(integration, @now)
      refute SyncSchedule.stale?(integration, @now)
    end
  end

  describe "due?/2" do
    test "Google and Outlook are due on every sweep" do
      assert SyncSchedule.due?(synced("google", 1), @now)
      assert SyncSchedule.due?(synced("outlook", 1), @now)
    end

    test "the debug provider is never swept" do
      refute SyncSchedule.due?(synced("debug", 10_000), @now)
    end

    test "a subscription and an Exchange mailbox are due after 30 minutes" do
      for provider <- ["ics_url", "exchange"] do
        refute SyncSchedule.due?(synced(provider, 29), @now)
        assert SyncSchedule.due?(synced(provider, 31), @now)
      end
    end

    for {tier, minutes} <- [{1, 15}, {2, 30}, {3, 60}, {nil, 15}] do
      test "a CalDAV integration on tier #{inspect(tier)} is due after #{minutes} minutes" do
        refute SyncSchedule.due?(
                 synced("caldav", unquote(minutes) - 1, caldav_sync_tier: unquote(tier)),
                 @now
               )

        assert SyncSchedule.due?(
                 synced("caldav", unquote(minutes) + 1, caldav_sync_tier: unquote(tier)),
                 @now
               )
      end
    end

    test "an integration never synced is due" do
      assert SyncSchedule.due?(synced("exchange", 0, last_external_sync_at: nil), @now)
    end
  end

  describe "stale?/2" do
    # Each threshold outlasts its provider's interval, so an integration
    # syncing on schedule never reads as stale.
    for {provider, attrs, minutes} <- [
          {"google", [], 30},
          {"ics_url", [], 75},
          {"exchange", [], 45},
          {"debug", [], 15},
          {"caldav", [caldav_sync_tier: 1], 25},
          {"caldav", [caldav_sync_tier: 3], 90}
        ] do
      test "#{provider} #{inspect(attrs)} is stale after #{minutes} minutes" do
        refute SyncSchedule.stale?(
                 synced(unquote(provider), unquote(minutes) - 1, unquote(attrs)),
                 @now
               )

        assert SyncSchedule.stale?(
                 synced(unquote(provider), unquote(minutes) + 1, unquote(attrs)),
                 @now
               )
      end
    end
  end

  describe "request_sync/1" do
    test "a CalDAV request forces a full fetch" do
      integration = insert(:calendar_integration, provider: "caldav")

      assert {:ok, _job} = SyncSchedule.request_sync(integration)

      assert [%{args: %{"force_full_fetch" => true}}] =
               all_enqueued(worker: SyncCalDavCalendarWorker)
    end

    # A request made while a sync waits is folded into it, for every
    # provider alike, rather than queueing a second read.
    for provider <- ["exchange", "ics_url", "debug"] do
      test "a repeat #{provider} request folds into the waiting one" do
        integration = insert(:calendar_integration, provider: unquote(provider))
        {:ok, %{worker: worker}} = SyncSchedule.schedule(integration)

        assert {:ok, %Oban.Job{conflict?: false}} = SyncSchedule.request_sync(integration)
        assert {:ok, %Oban.Job{conflict?: true}} = SyncSchedule.request_sync(integration)
        assert [_one] = all_enqueued(worker: worker)
      end
    end
  end

  describe "request_sync_unless_backing_off/1" do
    # A sync job of `integration` left in `state`, due four minutes from now.
    defp waiting_sync(integration, state, meta \\ %{}) do
      {:ok, %{worker: worker}} = SyncSchedule.schedule(integration)

      {:ok, job} =
        %{"calendar_integration_id" => integration.id} |> worker.new() |> Oban.insert()

      due = DateTime.add(DateTime.utc_now(), 240, :second)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [state: state, scheduled_at: due, attempt: 1, meta: meta]
      )

      Repo.get!(Oban.Job, job.id)
    end

    defp due_soon?(job) do
      %{scheduled_at: scheduled_at} = Repo.get!(Oban.Job, job.id)
      DateTime.before?(scheduled_at, DateTime.add(DateTime.utc_now(), 5, :second))
    end

    for provider <- ["google", "outlook", "caldav", "exchange", "ics_url"] do
      test "leaves a retrying #{provider} sync to its backoff" do
        integration = insert(:calendar_integration, provider: unquote(provider))
        retrying = waiting_sync(integration, "retryable")

        assert {:ok, :backing_off} = SyncSchedule.request_sync_unless_backing_off(integration)

        assert Repo.get!(Oban.Job, retrying.id).scheduled_at == retrying.scheduled_at
      end
    end

    test "leaves a sync snoozed past an open breaker to its snooze" do
      integration = insert(:calendar_integration, provider: "exchange")
      snoozed = waiting_sync(integration, "scheduled", %{"snoozed" => 1})

      assert {:ok, :backing_off} = SyncSchedule.request_sync_unless_backing_off(integration)

      refute due_soon?(snoozed)
    end

    test "brings forward a sync merely scheduled for later" do
      integration = insert(:calendar_integration, provider: "caldav")
      scheduled = waiting_sync(integration, "scheduled")

      assert {:ok, %Oban.Job{id: id}} =
               SyncSchedule.request_sync_unless_backing_off(integration)

      assert id == scheduled.id
      assert due_soon?(scheduled)
    end

    test "asks for a sync when none is waiting" do
      integration = insert(:calendar_integration, provider: "ics_url")

      assert {:ok, %Oban.Job{}} = SyncSchedule.request_sync_unless_backing_off(integration)

      assert_enqueued(
        worker: SyncIcsCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "leaves request_sync/1 bringing a retrying sync forward" do
      integration = insert(:calendar_integration, provider: "exchange")
      retrying = waiting_sync(integration, "retryable")

      assert {:ok, %Oban.Job{}} = SyncSchedule.request_sync(integration)

      assert due_soon?(retrying)
    end
  end
end
