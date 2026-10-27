defmodule Tymeslot.Integrations.Calendar.Google.SeriesRuleSyncTest do
  @moduledoc """
  A Google series' repeat rule, read from its recurring event as its
  instances are synced, and how that read answers when the recurring event
  cannot be read.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Google.SeriesMaster
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  # The breaker is a GenServer, so stubs must be visible from its process.
  setup :set_mox_global
  setup :verify_on_exit!

  @master %{
    "id" => "master1",
    "recurrence" => ["EXDATE;TZID=Europe/Berlin:20261012T090000", "RRULE:FREQ=WEEKLY;BYDAY=MO"],
    "start" => %{"dateTime" => "2026-10-05T09:00:00+02:00", "timeZone" => "Europe/Berlin"}
  }

  # The series' rule was read a minute ago, before the change the sync now
  # brings: a changed series is read again however fresh its rule is.
  test "a sync gives the instances their series' rule, read from the recurring event" do
    integration =
      insert(:calendar_integration, provider: "google", google_sync_token: "valid-token")

    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, "master1", %{
        rule: "FREQ=DAILY",
        master_start: nil,
        fetched_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      })

    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: [instance("master1_20261019T070000Z")], next_sync_token: "next"}}
    end)

    # The run lists the changed series' instances to sweep the ones gone.
    expect(GoogleCalendarAPIMock, :list_instances, fn _integration,
                                                      "primary",
                                                      "master1",
                                                      _from,
                                                      _to ->
      {:ok, [instance("master1_20261019T070000Z")]}
    end)

    expect(GoogleCalendarAPIMock, :get_series_master, fn _integration, "primary", "master1" ->
      {:ok, @master}
    end)

    assert :ok =
             perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

    rows = Repo.all(ProviderCalendarEventSchema)

    assert [%{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"}] =
             Enum.filter(rows, &(&1.calendar_integration_id == integration.id))

    assert %{master_start: ~U[2026-10-05 07:00:00Z]} =
             stored_rule(integration, "master1")
  end

  describe "a sync cycle" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: nil,
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "work@example.com", "selected" => true, "name" => "Work"}
          ]
        )

      test_pid = self()

      stub(GoogleCalendarAPIMock, :get_series_master, fn _integration, _calendar, master_id ->
        send(test_pid, {:master_read, master_id})
        {:ok, %{"recurrence" => ["RRULE:FREQ=DAILY"], "start" => %{"date" => "2026-10-05"}}}
      end)

      %{integration: integration}
    end

    # The other calendar is listed in full every run; its series' rules are
    # fresh after the first.
    test "reads no master again on a second run that changes nothing", %{
      integration: integration
    } do
      for _run <- 1..2 do
        expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
          {:ok, %{events: [], next_sync_token: "next"}}
        end)

        expect(GoogleCalendarAPIMock, :list_events, fn _integration,
                                                       "work@example.com",
                                                       _from,
                                                       _to ->
          {:ok, [series_instance("work-master", "2026-10-19")]}
        end)

        assert :ok =
                 perform_job(SyncGoogleCalendarWorker, %{
                   "calendar_integration_id" => integration.id
                 })
      end

      assert master_reads() == ["work-master"]
    end

    test "reads at most 50 masters across the booking and other calendars", %{
      integration: integration
    } do
      changed = for n <- 1..30, do: series_instance("booking-#{n}", "2026-10-19")
      listed = for n <- 1..30, do: series_instance("work-#{n}", "2026-10-19")

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: changed, next_sync_token: "next"}}
      end)

      stub(GoogleCalendarAPIMock, :list_instances, fn _integration,
                                                      _calendar,
                                                      master_id,
                                                      _from,
                                                      _to ->
        {:ok, Enum.filter(changed, &(&1["recurringEventId"] == master_id))}
      end)

      expect(GoogleCalendarAPIMock, :list_events, fn _integration,
                                                     "work@example.com",
                                                     _from,
                                                     _to ->
        {:ok, listed}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      reads = master_reads()
      assert length(reads) == 50
      assert Enum.uniq(reads) == reads
    end
  end

  describe "reading a recurring event" do
    setup do
      previous = Application.get_env(:tymeslot, :google_calendar_api_module)
      Application.put_env(:tymeslot, :google_calendar_api_module, GoogleAPI)
      CalendarCircuitBreaker.reset(:google)

      on_exit(fn ->
        Application.put_env(:tymeslot, :google_calendar_api_module, previous)
        CalendarCircuitBreaker.reset(:google)
      end)

      integration =
        insert(:calendar_integration,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("access-token"),
          refresh_token_encrypted: Encryption.encrypt("refresh-token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      %{integration: integration}
    end

    test "asks for its recurrence and start only, in the instance's calendar", %{
      integration: integration
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        send(test_pid, {:url, url})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(@master)}}
      end)

      assert {:ok, %{rule: "FREQ=WEEKLY;BYDAY=MO", master_start: ~U[2026-10-05 07:00:00Z]}} =
               SeriesMaster.read(integration, "master1", "work@example.com")

      assert_received {:url, url}
      %URI{path: path, query: query} = URI.parse(url)
      assert path =~ "/calendars/work%40example.com/events/master1"
      assert URI.decode_query(query)["fields"] == "id,recurrence,start"
    end

    test "reads an all-day series' start as its first day", %{integration: integration} do
      serve(200, %{"recurrence" => ["RRULE:FREQ=DAILY"], "start" => %{"date" => "2026-10-05"}})

      assert {:ok, %{rule: "FREQ=DAILY", master_start: ~U[2026-10-05 00:00:00Z]}} =
               SeriesMaster.read(integration, "master1", nil)
    end

    test "reads an event with no recurrence lines as having no rule", %{integration: integration} do
      serve(200, %{"start" => %{"dateTime" => "2026-10-05T09:00:00Z"}})

      assert {:ok, %{rule: nil}} = SeriesMaster.read(integration, "master1", nil)
    end

    for status <- [404, 410] do
      test "reads a #{status} as the recurring event being gone", %{integration: integration} do
        serve(unquote(status), %{"error" => %{"message" => "Not Found"}})

        assert SeriesMaster.read(integration, "master1", nil) == :gone
      end
    end

    test "stops at a rate limit", %{integration: integration} do
      serve(403, %{
        "error" => %{
          "message" => "Rate Limit Exceeded",
          "errors" => [%{"reason" => "rateLimitExceeded"}]
        }
      })

      assert SeriesMaster.read(integration, "master1", nil) == {:stop, :rate_limited}
    end

    test "stops without a request while the breaker is open", %{integration: integration} do
      for _n <- 1..10 do
        CalendarCircuitBreaker.call(:google, fn -> {:provider_error, :simulated_failure} end)
      end

      assert {:error, :circuit_open} =
               CalendarCircuitBreaker.call(:google, fn -> {:ok, :probe} end)

      assert SeriesMaster.read(integration, "master1", nil) == {:stop, :circuit_open}
    end
  end

  defp instance(id) do
    %{
      "id" => id,
      "iCalUID" => "master1@google.com",
      "recurringEventId" => "master1",
      "originalStartTime" => %{"dateTime" => "2026-10-19T09:00:00+02:00"},
      "status" => "confirmed",
      "summary" => "Weekly standup",
      "start" => %{"dateTime" => "2026-10-19T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-10-19T09:30:00+02:00", "timeZone" => "Europe/Berlin"}
    }
  end

  defp series_instance(master_id, date) do
    %{
      "id" => "#{master_id}_#{String.replace(date, "-", "")}",
      "iCalUID" => "#{master_id}@google.com",
      "recurringEventId" => master_id,
      "originalStartTime" => %{"date" => date},
      "status" => "confirmed",
      "summary" => "Series #{master_id}",
      "start" => %{"date" => date},
      "end" => %{"date" => Date.from_iso8601!(date) |> Date.add(1) |> Date.to_iso8601()}
    }
  end

  defp master_reads do
    receive do
      {:master_read, master_id} -> [master_id | master_reads()]
    after
      0 -> []
    end
  end

  defp serve(status, body) do
    expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: status, body: Jason.encode!(body)}}
    end)
  end

  # The series' stored row, or nil.
  defp stored_rule(integration, master_id),
    do: Map.get(SeriesRuleQueries.list_by_master(integration.id, [master_id]), master_id)
end
