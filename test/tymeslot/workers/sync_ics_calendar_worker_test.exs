defmodule Tymeslot.Workers.SyncIcsCalendarWorkerTest do
  @moduledoc """
  Covers the worker that refreshes a subscribed calendar feed into the local
  event cache: the full-replace semantics, the terminal-vs-retryable split on
  failure, and the sync state it stamps.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  @moduletag :workers
  @moduletag :calendar

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Ics.Provider, as: IcsProvider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  @feed_url "https://feeds.example.com/secret-address/basic.ics"

  @ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Example Corp//Publisher//EN
  BEGIN:VEVENT
  UID:from-feed@example.com
  DTSTART:20260810T090000Z
  DTEND:20260810T100000Z
  SUMMARY:Sprint planning
  END:VEVENT
  END:VCALENDAR
  """

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt(@feed_url)
      )

    %{user: user, integration: integration}
  end

  defp stub_feed(body, status \\ 200) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "text/calendar")
      |> Conn.send_resp(status, body)
    end)
  end

  defp cached_uids(integration) do
    [integration.id]
    |> ProviderCalendarEventQueries.list_for_range(
      ~U[2026-01-01 00:00:00Z],
      ~U[2027-01-01 00:00:00Z]
    )
    |> Enum.map(& &1.uid)
  end

  defp feed_with_events(count) do
    events =
      Enum.map_join(1..count, "\n", fn n ->
        """
        BEGIN:VEVENT
        UID:event-#{n}@example.com
        DTSTART:2026081#{n}T090000Z
        DTEND:2026081#{n}T100000Z
        SUMMARY:Event #{n}
        END:VEVENT\
        """
      end)

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Example Corp//Publisher//EN
    #{events}
    END:VCALENDAR
    """
  end

  describe "perform/1 on success" do
    test "caches the feed's events", %{integration: integration} do
      stub_feed(@ics)

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert cached_uids(integration) == ["from-feed@example.com"]
    end

    # RFC 5545 §3.3.6: a DURATION may combine days with a time part. Read as
    # the one-hour default, the event left 25 of its 26 hours free to book.
    test "an event with only a combined DURATION is busy for all of it", %{
      integration: integration
    } do
      stub_feed("""
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:offsite@example.com
      DTSTART:20260810T090000Z
      DURATION:P1DT2H
      SUMMARY:Offsite
      END:VEVENT
      END:VCALENDAR
      """)

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      client =
        integration
        |> CalendarIntegrationSchema.decrypt_credentials()
        |> IcsProvider.build_client_configs()
        |> hd()

      assert {:ok, [event]} =
               IcsProvider.list_events(client,
                 start_time: ~U[2026-08-01 00:00:00Z],
                 end_time: ~U[2026-08-31 23:59:59Z]
               )

      assert DateTime.compare(event.start_time, ~U[2026-08-10 09:00:00Z]) == :eq
      assert DateTime.compare(event.end_time, ~U[2026-08-11 11:00:00Z]) == :eq
    end

    test "replaces events that have disappeared from the feed", %{integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "cancelled-upstream",
        start_at: ~U[2026-08-09 09:00:00.000000Z],
        end_at: ~U[2026-08-09 10:00:00.000000Z]
      )

      stub_feed(@ics)

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      # A feed carries no deletions, so anything missing from the new fetch is
      # gone: the refresh must replace rather than merge.
      assert cached_uids(integration) == ["from-feed@example.com"]
    end

    test "empties the cache when the feed no longer holds any events and the cache was already empty",
         %{integration: integration} do
      stub_feed("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n")

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert cached_uids(integration) == []
    end

    test "a feed shrinking from 5 to 4 events still reconciles normally", %{
      integration: integration
    } do
      stub_feed(feed_with_events(5))

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert length(cached_uids(integration)) == 5

      stub_feed(feed_with_events(4))

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert length(cached_uids(integration)) == 4
    end

    test "stamps its own sync timestamps and clears a previous error", %{
      integration: integration
    } do
      {:ok, _flagged} =
        CalendarIntegrationQueries.mark_sync_error(integration, "previous failure")

      stub_feed(@ics)

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)

      assert refreshed.last_external_sync_at
      assert refreshed.last_full_sync_at
      refute refreshed.sync_error
      refute refreshed.needs_reauth
    end

    test "broadcasts completion so the grid's refresh spinner clears", %{
      user: user,
      integration: integration
    } do
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user.id}")
      stub_feed(@ics)

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert_receive {:calendar_sync_complete, user_id, integration_id}
      assert user_id == user.id
      assert integration_id == integration.id
    end
  end

  describe "perform/1 guards an empty feed against a populated cache" do
    test "keeps the cache and retries when the feed comes back empty but the cache is populated",
         %{integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "stale-event",
        start_at: ~U[2026-08-09 09:00:00.000000Z],
        end_at: ~U[2026-08-09 10:00:00.000000Z]
      )

      stub_feed("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n")

      assert {:error, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      # The suspicious empty read must not wipe the diary.
      assert cached_uids(integration) == ["stale-event"]

      {:ok, guarded} = CalendarIntegrationQueries.get(integration.id)
      refute guarded.needs_reauth
      assert guarded.sync_error =~ "empty"
    end
  end

  describe "perform/1 recovers from a crash while writing the cache" do
    test "records a sync error and preserves the cache when a poisoned event raises", %{
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "known-good",
        start_at: ~U[2026-08-09 09:00:00.000000Z],
        end_at: ~U[2026-08-09 10:00:00.000000Z]
      )

      # A null byte in a text field: valid UTF-8, so it survives parsing and
      # event validation, and Postgres refuses it at the insert. Stands in for
      # any payload a third-party feed can carry that only blows up once it
      # reaches the database.
      stub_feed("""
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Example Corp//Publisher//EN
      BEGIN:VEVENT
      UID:poison@example.com
      DTSTART:20260810T090000Z
      DTEND:20260810T100000Z
      SUMMARY:Poison\0event
      END:VEVENT
      END:VCALENDAR
      """)

      assert {:error, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      # The transaction must have rolled back rather than crash-looping with
      # a half-applied wipe.
      assert cached_uids(integration) == ["known-good"]

      {:ok, failed} = CalendarIntegrationQueries.get(integration.id)
      refute failed.needs_reauth

      assert failed.sync_error ==
               "Calendar subscription sync failed while saving a fetched event. Tymeslot will try again on the next sync."
    end
  end

  describe "perform/1 when credentials cannot be decrypted" do
    test "routes through the shared reauth path instead of silently discarding", %{
      user: user
    } do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "ics_url",
          base_url: "https://feeds.example.com",
          username_encrypted: nil,
          password_encrypted: nil,
          subscription_url_encrypted: :crypto.strong_rand_bytes(40)
        )

      assert {:discard, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      flagged = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert flagged.needs_reauth
      assert flagged.sync_error
    end
  end

  describe "perform/1 on failure" do
    test "discards and flags for reauth when the feed rejects the link", %{
      integration: integration
    } do
      stub_feed("", 401)

      assert {:discard, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      {:ok, flagged} = CalendarIntegrationQueries.get(integration.id)
      assert flagged.needs_reauth

      assert flagged.sync_error ==
               "The calendar feed rejected the stored link. It was probably revoked or reset — subscribe again with a fresh URL."
    end

    test "retries and records the error when the feed is temporarily unavailable", %{
      integration: integration
    } do
      stub_feed("", 503)

      assert {:error, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      {:ok, failed} = CalendarIntegrationQueries.get(integration.id)
      refute failed.needs_reauth
      assert failed.sync_error == "The calendar feed returned an error."
    end

    test "leaves the previously cached events in place when a fetch fails", %{
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "known-good",
        start_at: ~U[2026-08-09 09:00:00.000000Z],
        end_at: ~U[2026-08-09 10:00:00.000000Z]
      )

      stub_feed("", 503)

      assert {:error, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      # An unreachable publisher must not empty the organiser's diary.
      assert cached_uids(integration) == ["known-good"]
    end

    test "discards when the integration no longer exists" do
      assert {:discard, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => 0})
    end

    # `sync_error` reaches only an owner who opens the dashboard. The failure
    # streak is what raises the badge, sends the 48-hour notification and
    # eventually auto-pauses a feed the publisher has stopped serving.
    test "counts each failed refresh against the integration's health, and clears it on success",
         %{integration: integration} do
      stub_feed("", 503)

      for expected <- 1..2 do
        assert {:error, _reason} =
                 perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

        assert health(integration).consecutive_sync_failures == expected
      end

      stub_feed(@ics)

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert health(integration).consecutive_sync_failures == 0
    end
  end

  describe "enqueue/1" do
    test "enqueues one sync, and a repeat request folds into it", %{
      integration: integration
    } do
      assert {:ok, %Oban.Job{}} = SyncIcsCalendarWorker.enqueue(integration.id)
      assert {:ok, %Oban.Job{conflict?: true}} = SyncIcsCalendarWorker.enqueue(integration.id)

      assert [%Oban.Job{args: %{"calendar_integration_id" => id}}] =
               all_enqueued(worker: SyncIcsCalendarWorker)

      assert id == integration.id
    end
  end

  defp health(integration), do: Monitor.get_state(:calendar, integration.id, integration.user_id)

  # The feed is read, then the integration is deleted before the refresh
  # writes the cache: the write refuses, the failure the worker records finds
  # no row, and the job ends as one whose integration is gone.
  test "discards a refresh whose integration was deleted while the feed was read", %{
    integration: integration
  } do
    ReqTest.stub(:tymeslot_http, fn conn ->
      Repo.delete!(Repo.get!(CalendarIntegrationSchema, integration.id))

      conn
      |> Conn.put_resp_header("content-type", "text/calendar")
      |> Conn.send_resp(200, @ics)
    end)

    assert {:discard, "Integration not found"} =
             perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})
  end
end
