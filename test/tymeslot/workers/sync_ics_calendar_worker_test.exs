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
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
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

  describe "perform/1 on success" do
    test "caches the feed's events", %{integration: integration} do
      stub_feed(@ics)

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert cached_uids(integration) == ["from-feed@example.com"]
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

    test "empties the cache when the feed no longer holds any events", %{
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "ics_url",
        provider_calendar_id: "subscription",
        uid: "stale-event",
        start_at: ~U[2026-08-09 09:00:00.000000Z],
        end_at: ~U[2026-08-09 10:00:00.000000Z]
      )

      stub_feed("BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n")

      assert :ok =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      assert cached_uids(integration) == []
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

      assert refreshed.last_sync_at
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

  describe "perform/1 on failure" do
    test "discards and flags for reauth when the feed rejects the link", %{
      integration: integration
    } do
      stub_feed("", 401)

      assert {:discard, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      {:ok, flagged} = CalendarIntegrationQueries.get(integration.id)
      assert flagged.needs_reauth
      assert flagged.sync_error =~ "revoked"
    end

    test "retries and records the error when the feed is temporarily unavailable", %{
      integration: integration
    } do
      stub_feed("", 503)

      assert {:error, _reason} =
               perform_job(SyncIcsCalendarWorker, %{"calendar_integration_id" => integration.id})

      {:ok, failed} = CalendarIntegrationQueries.get(integration.id)
      refute failed.needs_reauth
      assert failed.sync_error =~ "503"
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
  end
end
