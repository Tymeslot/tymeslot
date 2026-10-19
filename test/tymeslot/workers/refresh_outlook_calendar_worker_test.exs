defmodule Tymeslot.Workers.RefreshOutlookCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker

  # set_mox_global so expectations are visible from the AccessToken / circuit
  # breaker process boundary that DeltaSync hops through.
  setup :set_mox_global
  setup :verify_on_exit!

  defp outlook_integration(attrs) do
    defaults = [
      provider: "outlook",
      is_active: true,
      access_token_encrypted: Encryption.encrypt("test-access-token"),
      refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      # A delta link bootstrapped an hour ago: young enough to be used.
      last_full_sync_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, attrs))
  end

  defp expect_delta_page(events) do
    body =
      Jason.encode!(%{
        "value" => events,
        "@odata.deltaLink" =>
          "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
      })

    expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
      assert url =~ "$deltatoken=old"
      {:ok, %{status: 200, body: body}}
    end)
  end

  defp subscribe_to_sync_topic(user_id) do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user_id}")
  end

  describe "perform/1 without a stored delta link" do
    test "bootstraps a delta baseline, registers a subscription and broadcasts completion" do
      integration = outlook_integration(graph_delta_link: nil)
      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        assert received.id == integration.id
        {:ok, %{integration | graph_delta_link: "fresh-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:ok, integration}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, user_id, integration_id}
      assert user_id == integration.user_id
      assert integration_id == integration.id
    end

    test "still completes successfully when webhook registration is not configured" do
      integration = outlook_integration(graph_delta_link: nil)
      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        {:ok, %{received | graph_delta_link: "fresh-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, _user_id, _integration_id}
    end

    test "returns an error and does NOT register a subscription when bootstrap fails" do
      integration = outlook_integration(graph_delta_link: nil)
      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :circuit_open}
      end)

      # Mox would raise if register_graph_subscription were called — the test
      # passes only if the worker does not invoke it after a bootstrap failure.

      assert {:error, :bootstrap_failed} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      refute_receive {:calendar_sync_complete, _user_id, _integration_id}
    end
  end

  describe "perform/1 with a stored delta link" do
    test "delegates to delta sync, persists the new link and broadcasts completion" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      # Empty delta response (no changed/removed events) plus a fresh deltaLink.
      delta_response_body =
        Jason.encode!(%{
          "value" => [],
          "@odata.deltaLink" =>
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: delta_response_body}}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, user_id, integration_id}
      assert user_id == integration.user_id
      assert integration_id == integration.id

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert reloaded.graph_delta_link =~ "$deltatoken=fresh"
    end

    # The link tracks the window of the bootstrap that issued it, fixed at
    # those dates; a week on, it is replaced so the cache keeps reaching the
    # full window ahead. It is followed one last time first: the bootstrap
    # only upserts, so a removal pending on the old link would otherwise
    # leave a ghost event in the cache.
    for {label, bootstrapped_at} <- [
          {"a week old", -7 * 86_400},
          {"of unknown age", nil}
        ] do
      test "follows a delta link #{label} once more, then re-bootstraps" do
        bootstrapped_at =
          case unquote(bootstrapped_at) do
            nil -> nil
            seconds -> DateTime.add(DateTime.utc_now(:second), seconds, :second)
          end

        integration =
          outlook_integration(
            graph_delta_link:
              "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old",
            last_full_sync_at: bootstrapped_at
          )

        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "outlook",
          uid: "removed-on-the-old-link",
          provider_event_id: "removed-1"
        )

        expect_delta_page([
          %{"id" => "removed-1", "iCalUId" => "removed-on-the-old-link", "@removed" => %{}}
        ])

        expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
          # The old link was followed before the bootstrap ran.
          assert received.graph_delta_link =~ "$deltatoken=fresh"
          {:ok, %{received | graph_delta_link: "fresh-delta-link"}}
        end)

        expect(OutlookCalendarAPIMock, :register_graph_subscription, fn updated ->
          {:ok, updated}
        end)

        assert :ok =
                 perform_job(RefreshOutlookCalendarWorker, %{
                   "calendar_integration_id" => integration.id
                 })

        assert ProviderCalendarEventQueries.get_by_uid(integration.id, "removed-on-the-old-link") ==
                 {:error, :not_found}
      end
    end

    test "keeps the old link's changes when the re-bootstrap fails" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old",
          last_full_sync_at: nil
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      expect_delta_page([])

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :too_many_pages}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, _user_id, _integration_id}

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert reloaded.graph_delta_link =~ "$deltatoken=fresh"
      assert is_nil(reloaded.last_full_sync_at)
    end

    test "re-bootstraps when following the old link fails" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old",
          last_full_sync_at: nil
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "boom"}}
      end)

      # Stores the new link as the real bootstrap does.
      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        now = DateTime.utc_now(:second)
        attrs = %{graph_delta_link: "fresh-bootstrap-link", last_full_sync_at: now}
        CalendarIntegrationWebhookQueries.update_graph_subscription(received, attrs)
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn updated ->
        assert updated.graph_delta_link == "fresh-bootstrap-link"
        {:ok, updated}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, _user_id, _integration_id}

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert reloaded.graph_delta_link == "fresh-bootstrap-link"
      assert %DateTime{} = reloaded.last_full_sync_at
    end

    test "retries when both the old link and the re-bootstrap fail" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old",
          last_full_sync_at: nil
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "boom"}}
      end)

      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :circuit_open}
      end)

      assert {:error, :bootstrap_failed} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end

    # One event Graph returns with a NUL byte used to fail the batch's cache
    # write, so the new link was never stored and every later refresh failed
    # on the same event.
    test "stores the new link when an event carries a NUL byte" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"
        )

      expect_delta_page([
        %{
          "id" => "nul-1",
          "iCalUId" => "nul-uid-1",
          "subject" => "Stand\u0000up",
          "start" => %{"dateTime" => "2026-11-02T09:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-11-02T09:15:00.0000000", "timeZone" => "UTC"}
        }
      ])

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert {:ok, %{summary: "Standup"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "nul-uid-1")

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert reloaded.graph_delta_link =~ "$deltatoken=fresh"
    end

    test "chains into bootstrap in the same job when the obsolete-link auto-clear fires" do
      # Existing integrations may carry a `/me/events/delta` link from the old
      # bootstrap path. DeltaSync detects and clears it; the worker must then
      # finish the job by bootstrapping a fresh `calendarView/delta` baseline,
      # not punt to an Oban retry — otherwise the first click would do nothing
      # visible.
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=obsolete"
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      # Bootstrap must run inside this job, not on a later retry.
      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        assert received.id == integration.id
        assert is_nil(received.graph_delta_link)
        {:ok, %{received | graph_delta_link: "fresh-calendarview-delta-link"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      # Mox would raise if any HTTP request fires against the obsolete URL.

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, _user_id, _integration_id}
    end

    test "returns an error and does not broadcast when delta sync fails" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"
        )

      :ok = subscribe_to_sync_topic(integration.user_id)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "boom"}}
      end)

      assert {:error, :delta_sync_failed} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      refute_receive {:calendar_sync_complete, _user_id, _integration_id}
    end
  end

  describe "perform/1 input validation" do
    test "discards when the integration does not exist" do
      assert {:discard, "Integration not found"} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => 999_999_999
               })
    end

    test "discards when the integration is not an Outlook one" do
      # A Google integration accidentally routed here (factory bug, stale args,
      # etc.) must NOT trigger Outlook-specific API calls. Mox would raise on
      # any unexpected call.
      integration = insert(:calendar_integration, provider: "google", is_active: true)

      assert {:discard, "Integration is not outlook"} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end

  describe "backoff/1" do
    # A transient Microsoft Graph outage (HTTP 500s, connection timeouts) must
    # not exhaust the job. Oban's default schedule burns every attempt inside
    # ~70 seconds, which turns a one-minute upstream blip into a permanently
    # discarded sync and an operator alert.
    test "spreads retries over minutes, finishing before the next fallback sweep" do
      max_attempts = RefreshOutlookCalendarWorker.new(%{}).changes.max_attempts

      elapsed_at_each_retry =
        Enum.scan(1..(max_attempts - 1), 0, fn attempt, elapsed ->
          elapsed + RefreshOutlookCalendarWorker.backoff(%Oban.Job{attempt: attempt})
        end)

      last_retry_at = List.last(elapsed_at_each_retry)

      # Long enough to ride out an outage lasting several minutes...
      assert last_retry_at >= 600

      # ...but spent before FallbackSyncSweepWorker (`*/15 * * * *`) enqueues
      # the next refresh for the same integration.
      assert last_retry_at < 900
    end

    test "waits longer after each successive failure" do
      gaps = Enum.map(1..4, &RefreshOutlookCalendarWorker.backoff(%Oban.Job{attempt: &1}))

      assert gaps == Enum.sort(gaps)
      assert Enum.uniq(gaps) == gaps
    end
  end

  describe "perform/1 when Microsoft Graph is transiently unwell" do
    setup do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=current"
        )

      stub(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: ""}}
      end)

      %{integration: integration}
    end

    test "fails, so Oban retries, while attempts remain", %{integration: integration} do
      assert {:error, :delta_sync_failed} =
               perform_job(
                 RefreshOutlookCalendarWorker,
                 %{"calendar_integration_id" => integration.id},
                 attempt: 1,
                 max_attempts: 5
               )
    end

    test "discards once the retry ladder is spent, rather than alerting an operator",
         %{integration: integration} do
      # A discard reaches Oban as `job:stop`, which error tracking never
      # records; only an unhandled `{:error, _}` is recorded and can alert an
      # operator. FallbackSyncSweepWorker re-enqueues this
      # integration within 15 minutes, and a remote that never recovers is the
      # health check's job to report.
      assert {:discard, message} =
               perform_job(
                 RefreshOutlookCalendarWorker,
                 %{"calendar_integration_id" => integration.id},
                 attempt: 5,
                 max_attempts: 5
               )

      assert message =~ "next scheduled sweep"
    end
  end

  describe "perform/1 when the failure is not the remote's fault" do
    test "still fails on the last attempt, so a bad credential keeps alerting" do
      # A token refresh that fails is the credential path — exactly what an
      # operator needs to hear about — so it must not take the transient
      # discard shortcut, even with every attempt spent.
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=current",
          token_expires_at: nil
        )

      expect(OutlookCalendarAPIMock, :refresh_token, fn _integration ->
        {:error, :api_error, "Token refresh failed"}
      end)

      assert {:error, :delta_sync_failed} =
               perform_job(
                 RefreshOutlookCalendarWorker,
                 %{"calendar_integration_id" => integration.id},
                 attempt: 5,
                 max_attempts: 5
               )
    end
  end

  # The refresh is the only full Outlook sync for an integration without
  # webhooks, so its verdict has to reach health state like every other
  # provider's sync, and a refused credential has to reach the owner.
  describe "perform/1 - health state" do
    defp delta_link, do: "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"

    test "a completed refresh clears a reconnect flag the integration has recovered from" do
      integration = outlook_integration(graph_delta_link: delta_link(), needs_reauth: true)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %{status: 200, body: Jason.encode!(%{"value" => [], "@odata.deltaLink" => delta_link()})}}
      end)

      assert :ok =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert {:ok, %{needs_reauth: false}} = CalendarIntegrationQueries.get(integration.id)
    end

    test "a failed refresh counts towards the failure streak" do
      integration = outlook_integration(graph_delta_link: delta_link())

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: ~s({"error":"server_error"})}}
      end)

      assert {:error, _reason} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert Monitor.get_state(:calendar, integration.id, integration.user_id).consecutive_sync_failures ==
               1
    end

    test "a refused credential flags the integration for reconnection instead of retrying" do
      integration = outlook_integration(graph_delta_link: delta_link())

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}
      end)

      assert {:discard, _reason} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert {:ok, %{needs_reauth: true}} = CalendarIntegrationQueries.get(integration.id)
    end

    test "a refused credential stores the untranslated reason whatever the locale" do
      integration = outlook_integration(graph_delta_link: delta_link())

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}
      end)

      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      assert {:discard, _reason} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert {:ok, %{sync_error: sync_error}} = CalendarIntegrationQueries.get(integration.id)

      assert sync_error ==
               "Microsoft rejected the stored credentials. Please reconnect the integration."
    end

    test "a refresh token Microsoft has revoked flags the integration instead of retrying" do
      integration =
        outlook_integration(
          graph_delta_link: delta_link(),
          token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      expect(OutlookCalendarAPIMock, :refresh_token, fn _integration ->
        {:error, :unauthorized, "invalid_grant: the refresh token has been revoked"}
      end)

      assert {:discard, _reason} =
               perform_job(RefreshOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert {:ok, %{needs_reauth: true}} = CalendarIntegrationQueries.get(integration.id)
    end
  end
end
