defmodule Tymeslot.Integrations.Calendar.Outlook.OccurrenceStubsSyncTest do
  @moduledoc """
  The occurrences Graph's `calendarView/delta` lists as stubs (timing and
  identity only), cached by the delta sweep and the bootstrap with what
  their series' master says: its title, all-day timing and free/busy.
  Down to the HTTP client.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Mox

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync
  alias Tymeslot.Integrations.Calendar.Outlook.GraphSubscription
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter

  # The breaker is a GenServer, so stubs must be visible from its process.
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:tymeslot, :outlook_calendar_api_module)
    Application.put_env(:tymeslot, :outlook_calendar_api_module, OutlookAPI)
    CalendarCircuitBreaker.reset(:outlook)

    on_exit(fn ->
      Application.put_env(:tymeslot, :outlook_calendar_api_module, previous)
      CalendarCircuitBreaker.reset(:outlook)
    end)

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

    %{integration: integration}
  end

  describe "a delta sweep" do
    test "caches a stub of an all-day series as an all-day occurrence with the series' title",
         %{integration: integration} do
      serve(
        delta: [all_day_master(), stub("occ-1", "2026-11-09")],
        masters: %{"master-1" => all_day_master()}
      )

      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert %{
               all_day: true,
               start_date: ~D[2026-11-09],
               end_date: ~D[2026-11-10],
               start_at: nil,
               end_at: nil,
               summary: "Holiday",
               transparency: "transparent"
             } = cached(integration, "occ-1")

      # The series rule's read only: the stub is completed from the listing.
      assert master_reads() == ["master-1"]
    end

    test "reads the master of a stub the delta lists without it", %{integration: integration} do
      serve(delta: [stub("occ-1", "2026-11-09")], masters: %{"master-1" => all_day_master()})

      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert %{all_day: true, start_date: ~D[2026-11-09], summary: "Holiday"} =
               cached(integration, "occ-1")

      # The one read completes the stub and gives the series its rule.
      assert master_reads() == ["master-1"]
      assert %{rule: "FREQ=DAILY;COUNT=3"} = stored_rule(integration, "master-1")
    end

    test "keeps an occurrence Graph lists in full as it is", %{integration: integration} do
      exception =
        "occ-2"
        |> stub("2026-11-10")
        |> Map.merge(%{"type" => "exception", "subject" => "Moved", "isAllDay" => true})

      serve(delta: [all_day_master(), exception], masters: %{"master-1" => all_day_master()})

      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert %{summary: "Moved", all_day: true, start_date: ~D[2026-11-10]} =
               cached(integration, "occ-2")
    end

    test "still caches a stub whose master cannot be read", %{integration: integration} do
      serve(
        delta: [stub("occ-1", "2026-11-09")],
        masters: %{"master-1" => {404, %{"error" => %{"code" => "ErrorItemNotFound"}}}}
      )

      log =
        capture_log(fn ->
          assert :ok = DeltaSync.fetch_and_apply(integration)
        end)

      assert %{summary: nil, all_day: false} = cached(integration, "occ-1")
      assert log =~ "Could not read an Outlook series master"
    end

    test "completes a stub a throttled master read left as it came on the next sweep",
         %{integration: integration} do
      serve(delta: [stub("occ-1", "2026-11-09")], masters: %{"master-1" => throttled()})
      capture_log(fn -> assert :ok = DeltaSync.fetch_and_apply(integration) end)

      assert %{summary: nil, all_day: false} = cached(integration, "occ-1")
      assert master_reads() == ["master-1"]

      # The next delta has nothing new to say about the occurrence.
      serve(delta: [], masters: %{"master-1" => all_day_master()})
      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert %{all_day: true, start_date: ~D[2026-11-09], summary: "Holiday"} =
               cached(integration, "occ-1")

      assert master_reads() == ["master-1"]

      # Completed, the stub is not read for again.
      assert :ok = DeltaSync.fetch_and_apply(integration)
      assert master_reads() == []
    end

    test "does not bring back a stub left as it came that the next delta removes",
         %{integration: integration} do
      serve(delta: [stub("occ-1", "2026-11-09")], masters: %{"master-1" => throttled()})
      capture_log(fn -> assert :ok = DeltaSync.fetch_and_apply(integration) end)
      assert %{summary: nil} = cached(integration, "occ-1")

      serve(
        delta: [%{"id" => "occ-1", "@removed" => %{"reason" => "deleted"}}],
        masters: %{"master-1" => all_day_master()}
      )

      assert :ok = DeltaSync.fetch_and_apply(integration)

      # Retried, the master being readable now, it would be cached again.
      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "occ-1")
    end

    test "stops reading masters at the first read that fails", %{integration: integration} do
      serve(
        delta: [
          stub("occ-1", "2026-11-09"),
          Map.put(stub("occ-2", "2026-11-09"), "seriesMasterId", "master-2")
        ],
        masters: %{"master-1" => throttled(), "master-2" => all_day_master("master-2")}
      )

      capture_log(fn -> assert :ok = DeltaSync.fetch_and_apply(integration) end)

      assert master_reads() == ["master-1"]
      assert %{summary: nil} = cached(integration, "occ-2")
    end

    test "reads no master once the integration's master read budget is spent",
         %{integration: integration} do
      for _n <- 1..50, do: :ok = RateLimiter.check(:series_rule_read, integration.id)

      serve(delta: [stub("occ-1", "2026-11-09")], masters: %{"master-1" => all_day_master()})
      capture_log(fn -> assert :ok = DeltaSync.fetch_and_apply(integration) end)

      assert master_reads() == []
      assert %{summary: nil, all_day: false} = cached(integration, "occ-1")
    end
  end

  test "a bootstrap caches a stub of an all-day series as an all-day occurrence", %{
    integration: integration
  } do
    serve(
      delta: [all_day_master(), stub("occ-1", "2026-11-09")],
      masters: %{"master-1" => all_day_master()}
    )

    assert {:ok, _integration} =
             GraphSubscription.bootstrap_sync(%{integration | graph_delta_link: nil})

    assert %{all_day: true, start_date: ~D[2026-11-09], summary: "Holiday"} =
             cached(integration, "occ-1")
  end

  # A stub as Graph's delta lists it: nothing but its identity and timing.
  defp stub(id, date) do
    next = date |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601()

    %{
      "@odata.type" => "#microsoft.graph.event",
      "@odata.etag" => ~s(W/"etag-#{id}"),
      "id" => id,
      "type" => "occurrence",
      "seriesMasterId" => "master-1",
      "start" => %{"dateTime" => "#{date}T00:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "#{next}T00:00:00.0000000", "timeZone" => "UTC"}
    }
  end

  defp throttled, do: {429, %{"error" => %{"code" => "TooManyRequests"}}}

  defp all_day_master(id \\ "master-1") do
    %{
      "id" => id,
      "iCalUId" => "ical-#{id}",
      "type" => "seriesMaster",
      "subject" => "Holiday",
      "isAllDay" => true,
      "showAs" => "free",
      "start" => %{"dateTime" => "2026-11-09T00:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-11-10T00:00:00.0000000", "timeZone" => "UTC"},
      "recurrence" => %{
        "pattern" => %{"type" => "daily", "interval" => 1},
        "range" => %{
          "type" => "numbered",
          "numberOfOccurrences" => 3,
          "startDate" => "2026-11-09"
        }
      }
    }
  end

  # Answers the delta pages and master reads Graph would, reporting each
  # master read to the test process.
  defp serve(opts) do
    test_pid = self()
    delta = Keyword.get(opts, :delta, [])
    masters = Keyword.get(opts, :masters, %{})

    stub(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
      %URI{path: path} = URI.parse(url)

      if String.ends_with?(path, "/delta") do
        ok(%{
          "value" => delta,
          "@odata.deltaLink" =>
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
        })
      else
        id = path |> String.split("/") |> List.last()
        send(test_pid, {:master_read, id})
        answer(Map.fetch!(masters, id))
      end
    end)
  end

  defp answer({status, body}), do: {:ok, %Req.Response{status: status, body: Jason.encode!(body)}}
  defp answer(body), do: ok(body)

  defp ok(body), do: {:ok, %Req.Response{status: 200, body: Jason.encode!(body)}}

  defp master_reads do
    receive do
      {:master_read, id} -> [id | master_reads()]
    after
      0 -> []
    end
  end

  defp stored_rule(integration, master_id) do
    Map.get(SeriesRuleQueries.list_by_master(integration.id, [master_id]), master_id)
  end

  # A stub has no `iCalUId`, so it is cached under its Graph id.
  defp cached(integration, id) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, id)
    row
  end
end
