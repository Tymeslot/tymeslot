defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesRuleSyncTest do
  @moduledoc """
  An Outlook series' repeat rule, read from its master as its occurrences are
  synced, down to the HTTP client: by the delta sweep, the bootstrap and the
  webhook fetch, and what happens when the master cannot be read.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

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
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  # The breaker is a GenServer, so stubs must be visible from its process.
  setup :set_mox_global
  setup :verify_on_exit!

  @weekly %{
    "pattern" => %{
      "type" => "weekly",
      "interval" => 1,
      "daysOfWeek" => ["monday"],
      "firstDayOfWeek" => "monday"
    },
    "range" => %{"type" => "noEnd", "startDate" => "2026-10-05"}
  }

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
    test "gives the occurrences their series' rule, read from the master", %{
      integration: integration
    } do
      serve(delta: [occurrence("occ-1", "master-1")], masters: %{"master-1" => master()})

      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert rule_of(integration, "occ-1") == "FREQ=WEEKLY;BYDAY=MO"

      assert %{master_start: ~U[2026-10-05 07:00:00Z]} =
               stored_rule(integration, "master-1")
    end

    test "caches the occurrences without a rule when the master is gone", %{
      integration: integration
    } do
      serve(delta: [occurrence("occ-1", "master-1")], masters: %{"master-1" => {404, %{}}})

      assert :ok = DeltaSync.fetch_and_apply(integration)

      assert rule_of(integration, "occ-1") == nil
      assert %{rule: nil} = stored_rule(integration, "master-1")
    end

    test "reads no further master once Graph throttles, and still caches every occurrence", %{
      integration: integration
    } do
      serve(
        delta: [occurrence("occ-1", "master-1"), occurrence("occ-2", "master-2")],
        masters: %{"master-1" => {429, %{}}, "master-2" => master()}
      )

      capture_log(fn -> assert :ok = DeltaSync.fetch_and_apply(integration) end)

      assert master_reads() == ["master-1"]
      assert rule_of(integration, "occ-1") == nil
      assert rule_of(integration, "occ-2") == nil
    end

    test "reads no master while the breaker is open", %{integration: integration} do
      serve(delta: [occurrence("occ-1", "master-1")], masters: %{"master-1" => master()})
      open_breaker()

      capture_log(fn -> DeltaSync.fetch_and_apply(integration) end)

      assert master_reads() == []
    end

    test "forgets the rule of a series whose occurrences are all removed", %{
      integration: integration
    } do
      serve(delta: [occurrence("occ-1", "master-1")], masters: %{"master-1" => master()})
      :ok = DeltaSync.fetch_and_apply(integration)
      assert %{rule: "FREQ=WEEKLY;BYDAY=MO"} = stored_rule(integration, "master-1")

      serve(delta: [%{"id" => "occ-1", "@removed" => %{"reason" => "deleted"}}], masters: %{})
      :ok = DeltaSync.fetch_and_apply(integration)

      assert stored_rule(integration, "master-1") == nil
    end
  end

  test "a bootstrap gives the occurrences their series' rule", %{integration: integration} do
    serve(delta: [occurrence("occ-1", "master-1")], masters: %{"master-1" => master()})

    assert {:ok, _integration} =
             GraphSubscription.bootstrap_sync(%{integration | graph_delta_link: nil})

    assert rule_of(integration, "occ-1") == "FREQ=WEEKLY;BYDAY=MO"
  end

  # A bootstrap is a listing: it changes nothing a fresh rule needs reading
  # again for.
  test "a second bootstrap reads no master whose rule is fresh", %{integration: integration} do
    serve(delta: [occurrence("occ-1", "master-1")], masters: %{"master-1" => master()})

    for _run <- 1..2 do
      assert {:ok, _integration} =
               GraphSubscription.bootstrap_sync(%{integration | graph_delta_link: nil})
    end

    assert master_reads() == ["master-1"]
  end

  test "a webhook fetch gives the occurrence its series' rule", %{integration: integration} do
    serve(
      events: %{"occ-1" => occurrence("occ-1", "master-1")},
      masters: %{"master-1" => master()}
    )

    assert :ok =
             perform_job(SyncOutlookCalendarWorker, %{
               "calendar_integration_id" => integration.id,
               "graph_resource_id" => "occ-1"
             })

    assert rule_of(integration, "occ-1") == "FREQ=WEEKLY;BYDAY=MO"
  end

  defp occurrence(id, master_id) do
    %{
      "id" => id,
      "iCalUId" => "ical-#{id}",
      "type" => "occurrence",
      "seriesMasterId" => master_id,
      "subject" => "Weekly",
      "isAllDay" => false,
      "start" => %{"dateTime" => "2026-10-19T07:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-10-19T08:00:00.0000000", "timeZone" => "UTC"}
    }
  end

  defp master do
    %{
      "id" => "master-1",
      "type" => "seriesMaster",
      "start" => %{"dateTime" => "2026-10-05T07:00:00.0000000", "timeZone" => "UTC"},
      "recurrence" => @weekly
    }
  end

  # Answers the delta pages, single-event reads and master reads Graph would,
  # reporting each master read to the test process.
  defp serve(opts) do
    test_pid = self()
    delta = Keyword.get(opts, :delta, [])
    events = Keyword.get(opts, :events, %{})
    masters = Keyword.get(opts, :masters, %{})

    stub(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
      %URI{path: path, query: query} = URI.parse(url)
      select = URI.decode_query(query || "")["$select"]

      cond do
        String.ends_with?(path, "/delta") ->
          ok(%{
            "value" => delta,
            "@odata.deltaLink" =>
              "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
          })

        select == "id,type,recurrence,start" ->
          id = path |> String.split("/") |> List.last()
          send(test_pid, {:master_read, id})
          answer(Map.fetch!(masters, id))

        true ->
          id = path |> String.split("/") |> List.last()
          answer(Map.fetch!(events, id))
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

  # The breaker counts a provider-error shape as a failure.
  defp open_breaker do
    for _n <- 1..6 do
      CalendarCircuitBreaker.call(:outlook, fn -> {:provider_error, :simulated_failure} end)
    end

    assert {:error, :circuit_open} =
             CalendarCircuitBreaker.call(:outlook, fn -> {:ok, :probe} end)
  end

  defp rule_of(integration, provider_event_id) do
    {:ok, row} =
      ProviderCalendarEventQueries.get_by_uid(integration.id, "ical-" <> provider_event_id)

    row.recurrence_rule
  end

  # The series' stored row, or nil.
  defp stored_rule(integration, master_id),
    do: Map.get(SeriesRuleQueries.list_by_master(integration.id, [master_id]), master_id)
end
