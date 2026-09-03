defmodule Tymeslot.Integrations.Calendar.CalDAV.TierDemotionTest do
  @moduledoc """
  The sync tier is chosen from what a server advertises in its property list.
  Some servers advertise `sync-collection` and then refuse every REPORT that
  uses it: Infomaniak answers 500, and because the stored tier was never
  revisited, one production calendar retried that same refused request every
  fifteen minutes for twelve days and synced only on its daily forced full
  fetch.

  A refusal must therefore demote the integration to the tier that needs no
  extension, and the same cycle must still fetch the events. A server that
  simply failed to answer must not, or a blip of packet loss costs a working
  delta sync.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @empty_multistatus ~s(<?xml version="1.0"?><multistatus xmlns="DAV:"></multistatus>)

  @ctag_multistatus ~s(<?xml version="1.0"?><multistatus xmlns="DAV:" ) <>
                      ~s(xmlns:cs="http://calendarserver.org/ns/"><response><propstat><prop>) <>
                      ~s(<cs:getctag>ctag-1</cs:getctag></prop></propstat></response></multistatus>)

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})

    integration =
      insert(:calendar_integration,
        provider: "caldav",
        base_url: "http://localhost:65432",
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("s3cret"),
        calendar_paths: ["/calendars/alice/default/"],
        provider_account_id: "http://localhost:65432||alice",
        is_active: true,
        needs_reauth: false,
        # Detection has already run and believed the server's advertisement.
        caldav_sync_tier: 1,
        caldav_sync_token: nil
      )

    %{integration: integration}
  end

  defp stored_tier(integration) do
    Repo.get!(CalendarIntegrationSchema, integration.id).caldav_sync_tier
  end

  defp run_sync(integration) do
    perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})
  end

  # Answers the sync-collection REPORT with `sync_collection_response` and
  # everything else with an empty multistatus, so a demoted cycle completes.
  # `ctag` decides whether the server appears to support the getctag extension,
  # which is what separates a demotion to tier 2 from one to tier 3.
  defp stub_server(sync_collection_response, opts \\ []) do
    ctag? = Keyword.get(opts, :ctag, false)

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)

      cond do
        conn.method == "REPORT" and String.contains?(body, "sync-collection") ->
          sync_collection_response.(conn)

        ctag? and String.contains?(body, "getctag") ->
          respond(conn, @ctag_multistatus)

        true ->
          respond(conn, @empty_multistatus)
      end
    end)
  end

  defp respond(conn, xml) do
    conn
    |> Conn.put_resp_content_type("application/xml")
    |> Conn.send_resp(207, xml)
  end

  describe "a server that refuses the sync-collection it advertised" do
    test "demotes to the full-fetch tier and still syncs this cycle",
         %{integration: integration} do
      stub_server(fn conn -> Conn.send_resp(conn, 500, "Internal Server Error") end)

      assert :ok = run_sync(integration)

      # Tier 3 needs no extension, and the same run fell through to it rather
      # than leaving the cycle with nothing fetched.
      assert stored_tier(integration) == 3
    end

    test "demotes to the CTag tier when the server supports that instead",
         %{integration: integration} do
      # Dropping straight to a full fetch every cycle would punish a server
      # that is already struggling to answer. Tier 2 skips the fetch entirely
      # while the calendar is unchanged, and costs one PROPFIND to find out.
      stub_server(fn conn -> Conn.send_resp(conn, 500, "Internal Server Error") end, ctag: true)

      assert :ok = run_sync(integration)
      assert stored_tier(integration) == 2
    end

    test "demotes on a 405 as readily as on a 500", %{integration: integration} do
      # A server that answers "method not allowed" to a REPORT it advertised is
      # making the same claim as one that 500s: the feature is not there.
      stub_server(fn conn -> Conn.send_resp(conn, 405, "Method Not Allowed") end)

      assert :ok = run_sync(integration)
      assert stored_tier(integration) == 3
    end

    test "the next cycle goes straight to the full fetch", %{integration: integration} do
      stub_server(fn conn -> Conn.send_resp(conn, 500, "Internal Server Error") end)
      assert :ok = run_sync(integration)

      # Nothing may ask for sync-collection again while the demotion stands;
      # the whole point is that the refused request stops being sent.
      stub_server(fn conn ->
        send(self(), :asked_for_sync_collection)
        Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert :ok = run_sync(reloaded)

      refute_received :asked_for_sync_collection
      assert stored_tier(integration) == 3
    end
  end

  describe "a server that simply did not answer" do
    test "keeps delta sync rather than abandoning it over a transport failure",
         %{integration: integration} do
      # A timeout says nothing about which features the server supports, and
      # demoting on one would trade a working delta sync for packet loss.
      stub_server(fn conn -> ReqTest.transport_error(conn, :timeout) end)

      run_sync(integration)

      assert stored_tier(integration) == 1
    end
  end
end
