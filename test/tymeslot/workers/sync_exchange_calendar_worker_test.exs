defmodule Tymeslot.Workers.SyncExchangeCalendarWorkerTest do
  @moduledoc """
  Covers the worker that refreshes an Exchange mailbox into the local event
  cache.

  Exchange is the only provider whose sync writes two populations of rows from
  two different EWS operations, so most of what is asserted here is about
  keeping them apart: that availability is served from `GetUserAvailability`
  and never from the items, that neither half's refresh deletes the other's
  rows, that a busy interval actually removes a bookable slot, and that a
  synthesised uid can never reach the cancellation path a real provider event
  id would.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Exchange.IntervalNormaliser
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncExchangeCalendarWorker

  @busy_start "2026-09-03T09:00:00Z"
  @busy_end "2026-09-03T10:00:00Z"
  @other_busy_start "2026-09-04T09:00:00Z"
  @other_busy_end "2026-09-04T10:00:00Z"

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: "https://mail.example.com/EWS/Exchange.asmx",
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        calendar_list: []
      )

    %{user: user, integration: integration}
  end

  describe "the two halves of the cache" do
    test "serves availability from the free/busy read, never from the items", %{
      integration: integration
    } do
      stub_full_sync()

      assert :ok = run(integration)

      events = availability_events(integration)

      assert [event] = events
      assert String.starts_with?(event.uid, IntervalNormaliser.uid_prefix())
      assert event.start_at == ~U[2026-09-03 09:00:00.000000Z]
      assert event.end_at == ~U[2026-09-03 10:00:00.000000Z]

      # The item read answered a `Standup` at 10:00 on 1 September. It must not
      # be here: its dates are the ones a recurring master would lie about.
      refute Enum.any?(events, &(&1.uid == "uid-1"))
    end

    test "issues a GetUserAvailability request at all", %{integration: integration} do
      stub_full_sync()

      assert :ok = run(integration)

      assert Enum.any?(sent_requests(), &(&1 =~ "GetUserAvailability")),
             "the sync never asked GetUserAvailability, so availability came from the items"
    end

    test "shows the items on the grid and keeps the opaque intervals off it", %{
      integration: integration
    } do
      stub_full_sync()

      assert :ok = run(integration)

      rows = grid_rows(integration)

      assert [row] = rows
      assert row.uid == "uid-1"
      assert row.summary == "Standup"
      assert row.role == EventRole.display_only()

      refute Enum.any?(rows, &String.starts_with?(&1.uid, IntervalNormaliser.uid_prefix()))
    end

    test "writes both halves in one run, neither deleting the other", %{
      integration: integration
    } do
      stub_full_sync()

      assert :ok = run(integration)

      assert [_busy] = availability_events(integration)
      assert [_item] = grid_rows(integration)
    end

    test "keeps both halves across a second run", %{integration: integration} do
      stub_full_sync()
      assert :ok = run(integration)

      stub_full_sync(intervals: [{@other_busy_start, @other_busy_end}])
      assert :ok = run(integration)

      assert [busy] = availability_events(integration)
      assert busy.start_at == ~U[2026-09-04 09:00:00.000000Z]
      assert [item] = grid_rows(integration)
      assert item.uid == "uid-1"
    end

    test "replaces the busy half wholesale, so a vanished interval stops blocking", %{
      integration: integration
    } do
      stub_full_sync()
      assert :ok = run(integration)

      stub_full_sync(intervals: [{@other_busy_start, @other_busy_end}])
      assert :ok = run(integration)

      starts = Enum.map(availability_events(integration), & &1.start_at)
      assert starts == [~U[2026-09-04 09:00:00.000000Z]]
    end
  end

  describe "busy intervals and the availability calculation" do
    test "a busy interval removes a slot the schedule would otherwise offer", %{
      integration: integration
    } do
      %{profile_id: profile_id} = create_bookable_profile()
      date = next_bookable_weekday()

      stub_full_sync(
        intervals: [
          {iso(date, ~T[00:00:00]), iso(Date.add(date, 1), ~T[00:00:00])}
        ]
      )

      assert :ok = run(integration)

      {:ok, slots_without_events} =
        Calculate.available_slots(date, 30, "Etc/UTC", "Etc/UTC", [], %{profile_id: profile_id})

      assert slots_without_events != [],
             "the schedule offered nothing even before the busy interval was applied"

      events = CalendarEventQueries.in_range([integration.id], {date, date})

      {:ok, slots_with_events} =
        Calculate.available_slots(date, 30, "Etc/UTC", "Etc/UTC", events, %{
          profile_id: profile_id
        })

      assert slots_with_events == [],
             "the mailbox was busy all day yet slots were still offered: #{inspect(slots_with_events)}"
    end
  end

  describe "the synthesised uid" do
    test "never cancels a Tymeslot meeting whose uid collides with it", %{
      integration: integration,
      user: user
    } do
      stub_full_sync()
      assert :ok = run(integration)

      [busy] = availability_events(integration)

      meeting =
        insert(:meeting,
          organizer_user: user,
          calendar_integration_id: integration.id,
          uid: busy.uid,
          provider_event_id: nil,
          status: "confirmed"
        )

      # The interval disappears from the mailbox, so its row is deleted. A
      # reconciliation keyed on uid would resolve that deletion to the meeting
      # above and cancel it.
      stub_full_sync(intervals: [{@other_busy_start, @other_busy_end}])
      assert :ok = run(integration)

      reloaded = Repo.get!(MeetingSchema, meeting.id)

      assert reloaded.status == "confirmed"
      assert reloaded.calendar_sync_status != "externally_deleted"
    end

    test "carries a namespace no meeting uid or EWS identifier can produce", %{
      integration: integration
    } do
      stub_full_sync()
      assert :ok = run(integration)

      [busy] = availability_events(integration)

      assert String.starts_with?(busy.uid, "tymeslot:exchange-busy:")
      assert String.contains?(busy.uid, ":")
      refute String.match?(busy.uid, ~r/^[0-9a-fA-F-]+$/)
    end

    test "is stable across syncs, so an unchanged interval does not churn", %{
      integration: integration
    } do
      stub_full_sync()
      assert :ok = run(integration)
      [first] = availability_events(integration)

      stub_full_sync()
      assert :ok = run(integration)
      [second] = availability_events(integration)

      assert first.uid == second.uid
    end
  end

  describe "guards against emptying the cache" do
    test "refuses to report a booked mailbox as free when no busy time comes back", %{
      integration: integration
    } do
      stub_full_sync()
      assert :ok = run(integration)

      stub_full_sync(intervals: [])

      assert {:error, {:empty_result_with_populated_cache, "busy_only"}} = run(integration)

      assert [_busy] = availability_events(integration),
             "the busy half was wiped by an empty free/busy response"
    end

    test "refuses to empty the grid when the item read comes back empty", %{
      integration: integration
    } do
      stub_full_sync()
      assert :ok = run(integration)

      stub_ews([
        ExchangeFixtures.availability_response([{@busy_start, @busy_end}]),
        ExchangeFixtures.empty_find_item_response()
      ])

      assert {:error, {:empty_result_with_populated_cache, "display_only"}} = run(integration)

      assert [_item] = grid_rows(integration)
    end

    test "an empty free/busy response does not stop the grid half being judged on its own", %{
      integration: integration
    } do
      # Nothing cached yet, so an empty mailbox is believable and both halves
      # are written empty rather than refused.
      stub_ews([
        ExchangeFixtures.availability_response([]),
        ExchangeFixtures.empty_find_item_response()
      ])

      assert :ok = run(integration)
      assert availability_events(integration) == []
      assert grid_rows(integration) == []
    end
  end

  describe "failure handling" do
    test "flags the integration for reconnection when the credentials are rejected", %{
      integration: integration
    } do
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.resp(conn, 401, "Unauthorized") end)

      assert {:discard, _reason} = run(integration)
      assert %{needs_reauth: true} = Repo.reload!(integration)
    end

    test "discards a server error rather than exhausting its attempts on it", %{
      integration: integration
    } do
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.resp(conn, 503, "Service Unavailable") end)

      assert {:discard, reason} = run(integration)
      assert reason =~ "server error"

      assert %{sync_error: message} = Repo.reload!(integration)
      assert message =~ "Tymeslot will retry automatically"
    end

    test "records a retryable failure without touching the cache", %{integration: integration} do
      stub_full_sync()
      assert :ok = run(integration)

      ReqTest.stub(:tymeslot_http, fn conn -> Conn.resp(conn, 429, "Too Many Requests") end)

      assert {:error, :rate_limited} = run(integration)

      assert [_busy] = availability_events(integration)
      assert [_item] = grid_rows(integration)
    end

    test "discards the job when the integration no longer exists" do
      assert {:discard, _reason} =
               perform_job(SyncExchangeCalendarWorker, %{"calendar_integration_id" => 0})
    end
  end

  describe "sync state" do
    test "stamps the sync timestamps a successful run earns", %{integration: integration} do
      stub_full_sync()

      assert :ok = run(integration)

      reloaded = Repo.reload!(integration)

      assert %DateTime{} = reloaded.last_external_sync_at
      assert %DateTime{} = reloaded.last_full_sync_at
      assert reloaded.sync_error == nil
      refute reloaded.needs_reauth
    end
  end

  # --- Helpers ---

  defp run(integration) do
    perform_job(SyncExchangeCalendarWorker, %{"calendar_integration_id" => integration.id})
  end

  defp availability_events(integration) do
    CalendarEventQueries.in_range([integration.id], {window_start(), window_end()})
  end

  defp grid_rows(integration) do
    ProviderCalendarEventQueries.list_for_range([integration.id], window_start(), window_end())
  end

  defp window_start, do: DateTime.add(DateTime.utc_now(), -365, :day)
  defp window_end, do: DateTime.add(DateTime.utc_now(), 365, :day)

  defp iso(date, time) do
    date |> DateTime.new!(time, "Etc/UTC") |> DateTime.to_iso8601()
  end

  # The three round trips one run makes, in order: `GetUserAvailability`, then
  # `FindItem`, then the batched `GetItem`.
  defp stub_full_sync(opts \\ []) do
    intervals = Keyword.get(opts, :intervals, [{@busy_start, @busy_end}])

    stub_ews([
      ExchangeFixtures.availability_response(intervals),
      ExchangeFixtures.find_item_response(),
      ExchangeFixtures.get_item_response()
    ])
  end

  defp stub_ews(responses) do
    test_pid = self()
    counter = :counters.new(1, [])

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, request_body, conn} = Conn.read_body(conn)
      send(test_pid, {:ews_request, request_body})

      :counters.add(counter, 1, 1)

      case Enum.at(responses, :counters.get(counter, 1) - 1) do
        nil ->
          Conn.resp(conn, 500, "unexpected extra EWS request")

        body ->
          conn
          |> Conn.put_resp_content_type("text/xml")
          |> Conn.resp(200, body)
      end
    end)
  end

  defp sent_requests(acc \\ []) do
    receive do
      {:ews_request, body} -> sent_requests([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
