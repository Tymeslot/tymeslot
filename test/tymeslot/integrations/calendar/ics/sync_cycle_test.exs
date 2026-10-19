defmodule Tymeslot.Integrations.Calendar.Ics.SyncCycleTest do
  @moduledoc """
  One feed refresh, run without Oban: the full replacement it writes, and
  the outcome a failed one hands its caller with nothing recorded against
  the integration.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  @moduletag :calendar
  @moduletag :integrations

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Ics.SyncCycle
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Security.Encryption

  @feed_url "https://feeds.example.com/cycle/basic.ics"

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    inserted =
      insert(:calendar_integration,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt(@feed_url),
        sync_error: nil,
        needs_reauth: false
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    %{integration: integration}
  end

  defp stub_feed(body, status \\ 200) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "text/calendar")
      |> Conn.send_resp(status, body)
    end)
  end

  defp feed(uids) do
    start = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y%m%dT090000Z")
    finish = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y%m%dT100000Z")

    events =
      Enum.map_join(uids, "\n", fn uid ->
        "BEGIN:VEVENT\nUID:#{uid}\nDTSTART:#{start}\nDTEND:#{finish}\nSUMMARY:Busy\nEND:VEVENT"
      end)

    "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//EN\n#{events}\nEND:VCALENDAR\n"
  end

  defp cached_uids(integration) do
    {from, to} = Sync.window()

    [integration.id]
    |> ProviderCalendarEventQueries.list_for_range(from, to)
    |> Enum.map(& &1.uid)
    |> Enum.sort()
  end

  test "replaces the cache with the feed and stamps a full read", %{integration: integration} do
    stub_feed(feed(["a@example.com", "b@example.com"]))
    assert :ok = SyncCycle.run(integration)

    stub_feed(feed(["b@example.com"]))
    assert :ok = SyncCycle.run(integration)

    assert cached_uids(integration) == ["b@example.com"]

    assert {:ok, %{last_external_sync_at: %DateTime{}, last_full_sync_at: %DateTime{}}} =
             CalendarIntegrationQueries.get(integration.id)
  end

  test "a revoked feed URL is :unauthorised, with nothing recorded", %{integration: integration} do
    stub_feed("Forbidden", 403)

    assert {:error, :unauthorised} = SyncCycle.run(integration)

    assert {:ok, %{needs_reauth: false, sync_error: nil}} =
             CalendarIntegrationQueries.get(integration.id)
  end

  test "an empty feed over a populated cache is refused", %{integration: integration} do
    stub_feed(feed(["a@example.com"]))
    assert :ok = SyncCycle.run(integration)

    stub_feed(feed([]))
    assert {:error, :empty_feed_with_populated_cache} = SyncCycle.run(integration)
    assert cached_uids(integration) == ["a@example.com"]
  end
end
