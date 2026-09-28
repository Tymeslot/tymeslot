defmodule Tymeslot.Workers.SyncRequestTest do
  @moduledoc """
  A requested sync (the dashboard's Refresh, or a write that dropped a
  series' cached rows) is never absorbed by a sync that may have read the
  provider before it, while webhooks and the fallback sweep still fold into
  the one job an integration may have.

  The queue is drained for real, so the job's row goes through `executing`,
  and the request lands from inside the provider call, as a write confirmed
  while a sync runs does.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.CalDAVSyncTestFixtures
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.WorkerTestHelpers, only: [running_job: 2]

  alias Ecto.Changeset
  alias Oban.Worker
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Webhooks
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.FallbackSyncSweepWorker
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncRequest

  setup :set_mox_global
  setup :verify_on_exit!

  @live_states ~w(available scheduled executing retryable suspended)

  defp live_jobs(worker, integration_id) do
    worker_name = Worker.to_string(worker)

    Repo.all(
      from j in Oban.Job,
        where: j.worker == ^worker_name and j.state in @live_states,
        where: fragment("?->>'calendar_integration_id' = ?", j.args, ^to_string(integration_id))
    )
  end

  # A series of two daily occurrences from `day` at `time` UTC.
  defp daily_series(day, time) do
    start = DateTime.new!(day, time)
    stamp = &Calendar.strftime(&1, "%Y%m%dT%H%M%SZ")

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//Test//EN
    BEGIN:VEVENT
    UID:series@test
    DTSTART:#{stamp.(start)}
    DTEND:#{stamp.(DateTime.add(start, 3600, :second))}
    RRULE:FREQ=DAILY;COUNT=2
    SUMMARY:Standup
    END:VEVENT
    END:VCALENDAR
    """
  end

  defp drain(queue),
    do: Oban.drain_queue(queue: queue, with_scheduled: true, with_recursion: true)

  describe "a request while a Google sync runs" do
    setup do
      integration =
        insert(:calendar_integration, provider: "google", google_sync_token: "token-1")

      %{integration: integration}
    end

    test "runs the sync again once the running one finishes", %{integration: integration} do
      test_pid = self()

      expect(GoogleCalendarAPIMock, :list_events_incremental, 2, fn _integration ->
        if Process.get(:requested) == nil do
          Process.put(:requested, true)
          {:ok, _job} = SyncGoogleCalendarWorker.enqueue(integration.id)
        end

        send(test_pid, :listed)
        {:ok, %{events: [], next_sync_token: "token-2"}}
      end)

      {:ok, _job} =
        %{"calendar_integration_id" => integration.id}
        |> SyncGoogleCalendarWorker.new()
        |> Oban.insert()

      assert %{snoozed: 1, success: 1} = drain(:calendar_events)
      assert_received :listed
      assert_received :listed
      assert live_jobs(SyncGoogleCalendarWorker, integration.id) == []
    end

    test "webhooks and the sweep still fold into the one job", %{integration: integration} do
      integration =
        integration
        |> Changeset.change(
          google_channel_id: "channel-#{integration.id}",
          google_channel_secret: "secret-#{integration.id}"
        )
        |> Repo.update!()

      running =
        running_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

      {:ok, _job} = SyncGoogleCalendarWorker.enqueue(integration.id)

      :ok =
        Webhooks.handle_google_notification(
          integration.google_channel_id,
          integration.google_channel_secret
        )

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})
      {:ok, _job} = SyncGoogleCalendarWorker.enqueue(integration.id)

      assert [%{id: id, args: args}] = live_jobs(SyncGoogleCalendarWorker, integration.id)
      assert id == running.id
      assert Map.has_key?(args, "requested_at")
    end

    # Past the worker's uniqueness period a webhook would start a second sync
    # beside the running one; a request folds into it whatever its age.
    test "a request folds into a sync running longer than the uniqueness period", %{
      integration: integration
    } do
      running =
        running_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

      Repo.update_all(from(j in Oban.Job, where: j.id == ^running.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      {:ok, _job} = SyncGoogleCalendarWorker.enqueue(integration.id)

      assert [%{id: id}] = live_jobs(SyncGoogleCalendarWorker, integration.id)
      assert id == running.id
    end
  end

  describe "a request while an Outlook refresh runs" do
    test "runs the refresh again once the running one finishes" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          graph_delta_link: nil
        )

      test_pid = self()

      expect(OutlookCalendarAPIMock, :bootstrap_sync, 2, fn received ->
        if Process.get(:requested) == nil do
          Process.put(:requested, true)
          {:ok, _job} = RefreshOutlookCalendarWorker.enqueue(integration.id)
        end

        send(test_pid, :bootstrapped)
        {:ok, %{received | graph_delta_link: "delta-link"}}
      end)

      stub(OutlookCalendarAPIMock, :register_graph_subscription, fn updated -> {:ok, updated} end)

      {:ok, _job} =
        %{"calendar_integration_id" => integration.id}
        |> RefreshOutlookCalendarWorker.new()
        |> Oban.insert()

      assert %{snoozed: 1, success: 1} = drain(:calendar_integrations)
      assert_received :bootstrapped
      assert_received :bootstrapped
    end
  end

  describe "a CalDAV full fetch requested" do
    setup :set_req_test_to_shared

    setup do
      with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
      with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 1,
          calendar_paths: [path1()],
          caldav_sync_tokens: %{path1() => "token-1"}
        )

      %{integration: integration}
    end

    # Answers a delta REPORT with a sync-collection and a full one with a
    # calendar-query answer, reporting which it was asked for.
    defp serve_caldav(on_first_request) do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)

        if Process.get(:requested) == nil do
          Process.put(:requested, true)
          on_first_request.()
        end

        conn = Conn.put_resp_header(conn, "content-type", "application/xml")

        if body =~ "sync-collection" do
          send(test_pid, {:fetched, :delta})

          Conn.send_resp(
            conn,
            207,
            sync_collection_xml("#{path1()}event1.ics", ical_path1(), "token-2")
          )
        else
          send(test_pid, {:fetched, :full})
          Conn.send_resp(conn, 207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
        end
      end)
    end

    test "while a delta sync runs, a full fetch follows it", %{integration: integration} do
      serve_caldav(fn ->
        {:ok, _job} = SyncCalDavCalendarWorker.enqueue_full_fetch(integration.id)
      end)

      {:ok, _job} =
        %{"calendar_integration_id" => integration.id}
        |> SyncCalDavCalendarWorker.new()
        |> Oban.insert()

      assert %{snoozed: 1, success: 1} = drain(:calendar_events)
      assert_received {:fetched, :delta}
      assert_received {:fetched, :full}
      refute_received {:fetched, :delta}
    end

    # The running delta sync listed the series before it was moved, so it
    # writes the old occurrences back after the write dropped them; the full
    # fetch that follows removes them again and caches the series as moved.
    test "the occurrences a stale run writes back are gone after the full fetch", %{
      integration: integration
    } do
      day = Date.add(Date.utc_today(), 7)
      old_series = daily_series(day, ~T[09:00:00])
      moved_series = daily_series(day, ~T[14:00:00])
      href = "#{path1()}series.ics"
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        conn = Conn.put_resp_header(conn, "content-type", "application/xml")

        if body =~ "sync-collection" do
          {:ok, _job} = SyncCalDavCalendarWorker.enqueue_full_fetch(integration.id)
          send(test_pid, {:fetched, :delta})
          Conn.send_resp(conn, 207, sync_collection_xml(href, old_series, "token-2"))
        else
          send(test_pid, {:fetched, :full})
          Conn.send_resp(conn, 207, caldav_report_xml(href, moved_series))
        end
      end)

      {:ok, _job} =
        %{"calendar_integration_id" => integration.id}
        |> SyncCalDavCalendarWorker.new()
        |> Oban.insert()

      assert %{snoozed: 1, success: 1} = drain(:calendar_events)
      assert_received {:fetched, :delta}
      assert_received {:fetched, :full}

      starts =
        Repo.all(
          from e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id,
            order_by: e.start_at,
            select: e.start_at
        )

      assert Enum.map(starts, &DateTime.to_time/1) == [~T[14:00:00.000000], ~T[14:00:00.000000]]
    end

    test "a delta sync already waiting runs as the full fetch", %{integration: integration} do
      serve_caldav(fn -> :ok end)

      {:ok, _job} =
        %{"calendar_integration_id" => integration.id}
        |> SyncCalDavCalendarWorker.new()
        |> Oban.insert()

      {:ok, _job} = SyncCalDavCalendarWorker.enqueue_full_fetch(integration.id)

      assert [%{args: %{"force_full_fetch" => true}}] =
               live_jobs(SyncCalDavCalendarWorker, integration.id)

      assert %{success: 1} = drain(:calendar_events)
      assert_received {:fetched, :full}
      refute_received {:fetched, :delta}
    end

    test "the sweep's jittered full fetch is brought forward", %{integration: integration} do
      later = DateTime.add(DateTime.utc_now(), 600, :second)

      {:ok, _job} =
        %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
        |> SyncCalDavCalendarWorker.new(scheduled_at: later)
        |> Oban.insert()

      {:ok, _job} = SyncCalDavCalendarWorker.enqueue_full_fetch(integration.id)

      assert [%{scheduled_at: scheduled_at}] =
               live_jobs(SyncCalDavCalendarWorker, integration.id)

      assert DateTime.before?(scheduled_at, DateTime.add(DateTime.utc_now(), 5, :second))
    end

    test "a later sweep does not undo the request", %{integration: integration} do
      running_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})
      {:ok, _job} = SyncCalDavCalendarWorker.enqueue_full_fetch(integration.id)
      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      assert [%{args: %{"force_full_fetch" => true}}] =
               live_jobs(SyncCalDavCalendarWorker, integration.id)
    end
  end

  describe "rerun_if_requested/2" do
    test "leaves a run nobody asked to repeat as it was" do
      integration = insert(:calendar_integration, provider: "google")

      running =
        running_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert SyncRequest.rerun_if_requested(:ok, running) == :ok
      assert SyncRequest.rerun_if_requested({:error, :boom}, running) == {:error, :boom}
    end
  end
end
