defmodule Tymeslot.Integrations.Calendar.DiagnosticsSyncTest do
  @moduledoc """
  `Diagnostics.sync_and_read_cache/3`: one sync of an integration's event
  cache, as its worker runs it, read back as the grid reads it. Down to the
  HTTP client for Outlook.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Diagnostics
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Security.Encryption

  # The breaker is a GenServer, so stubs must be visible from its process.
  setup :set_mox_global
  setup :verify_on_exit!

  @range {~U[2026-11-01 00:00:00Z], ~U[2026-11-30 00:00:00Z]}

  setup do
    previous = Application.get_env(:tymeslot, :outlook_calendar_api_module)
    Application.put_env(:tymeslot, :outlook_calendar_api_module, OutlookAPI)
    CalendarCircuitBreaker.reset(:outlook)

    on_exit(fn ->
      Application.put_env(:tymeslot, :outlook_calendar_api_module, previous)
      CalendarCircuitBreaker.reset(:outlook)
    end)
  end

  test "syncs an Outlook integration and returns what it cached in the range" do
    integration =
      insert(:calendar_integration,
        provider: "outlook",
        is_active: true,
        access_token_encrypted: Encryption.encrypt("access-token"),
        refresh_token_encrypted: Encryption.encrypt("refresh-token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        last_full_sync_at: DateTime.add(DateTime.utc_now(:second), -3600, :second),
        graph_delta_link: "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"
      )

    stub(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "value" => [
               %{
                 "id" => "evt-1",
                 "iCalUId" => "ical-evt-1",
                 "type" => "singleInstance",
                 "subject" => "Holiday",
                 "isAllDay" => true,
                 "start" => %{"dateTime" => "2026-11-05T00:00:00.0000000", "timeZone" => "UTC"},
                 "end" => %{"dateTime" => "2026-11-06T00:00:00.0000000", "timeZone" => "UTC"}
               }
             ],
             "@odata.deltaLink" =>
               "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
           })
       }}
    end)

    {from, to} = @range

    assert {:ok, [%{summary: "Holiday", all_day: true, start_date: ~D[2026-11-05]}]} =
             Diagnostics.sync_and_read_cache(integration, from, to)
  end

  test "refuses a provider with no synced cache" do
    integration = insert(:calendar_integration, provider: "caldav")
    {from, to} = @range

    assert Diagnostics.sync_and_read_cache(integration, from, to) == {:error, :no_synced_cache}
  end
end
