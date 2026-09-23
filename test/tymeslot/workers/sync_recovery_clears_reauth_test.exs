defmodule Tymeslot.Workers.SyncRecoveryClearsReauthTest do
  @moduledoc """
  An integration that starts working again must be allowed to take bookings
  again.

  `needs_reauth` keeps a flagged integration out of every booking
  (`BookingIntegrationResolver.booking_target?/1` requires it to be false), and
  only two of the five sync workers used to clear it. A Google, Outlook or
  CalDAV-family integration that recovered without its owner touching anything
  — a CalDAV password fixed on the server, a provider outage that resolved —
  therefore kept refusing bookings for as long as nobody reconnected it by
  hand, however well it was syncing.

  These tests drive the real workers against a provider that answers, and
  assert the recovery through the resolver rather than the column: the column
  is bookkeeping, being bookable again is the thing the owner notices.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.CalDAVSyncTestFixtures
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  setup :set_mox_global
  setup :verify_on_exit!
  setup :set_req_test_to_shared

  # The owner's view of the flag: a booking can find no calendar to write to.
  defp resolves_to(integration), do: BookingIntegrationResolver.resolve(integration.user_id)

  defp flagged_integration(attrs) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          is_active: true,
          needs_reauth: true,
          sync_error: "The provider rejected the stored credentials."
        ],
        attrs
      )
    )
  end

  defp assert_bookable_again(integration) do
    assert %{id: resolved_id} = resolves_to(integration)
    assert resolved_id == integration.id

    reloaded = Repo.reload!(integration)
    assert reloaded.needs_reauth == false
    assert is_nil(reloaded.sync_error)
  end

  describe "a Google integration whose sync starts working again" do
    setup do
      integration =
        flagged_integration(
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary"
        )

      %{integration: integration}
    end

    test "becomes a booking target again", %{integration: integration} do
      assert is_nil(resolves_to(integration))

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "fresh-token"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_bookable_again(integration)
    end

    test "stays flagged when the cycle fails", %{integration: integration} do
      # The counterpart that makes the assertion above falsifiable: a cycle
      # that did not read the calendar proves nothing about the credentials,
      # so the flag and the message the dashboard shows both survive it.
      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :rate_limited, "Quota exceeded"}
      end)

      assert {:error, _reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert is_nil(resolves_to(integration))
      assert Repo.reload!(integration).needs_reauth == true
    end
  end

  describe "a CalDAV integration whose sync starts working again" do
    # Scoped to this block: the other two providers reach the network through
    # `Tymeslot.HTTPClientMock`, which swapping in the real client would
    # bypass.
    setup do
      with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
      with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
      :ok
    end

    test "becomes a booking target again" do
      # The case this is genuinely reachable for: a CalDAV password corrected
      # on the server restores access with nothing happening in Tymeslot, so
      # nothing but the next sync can ever notice.
      integration =
        flagged_integration(
          provider: "caldav",
          base_url: "http://localhost:65432",
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("s3cret"),
          calendar_paths: [path1()],
          caldav_sync_tier: 3
        )

      assert is_nil(resolves_to(integration))

      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
      end)

      assert :ok =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_bookable_again(integration)
    end
  end

  describe "an Outlook integration whose sync starts working again" do
    test "becomes a booking target again" do
      integration =
        flagged_integration(
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          default_booking_calendar_id: "primary"
        )

      assert is_nil(resolves_to(integration))

      graph_event =
        Jason.encode!(%{
          "id" => "outlook-recovered-1",
          "subject" => "Recovered",
          "start" => %{"dateTime" => "2026-04-07T09:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-04-07T10:00:00.0000000", "timeZone" => "UTC"},
          "showAs" => "busy",
          "attendees" => [],
          "type" => "singleInstance"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: graph_event}}
      end)

      assert :ok =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => "outlook-recovered-1"
               })

      assert_bookable_again(integration)
    end
  end
end
