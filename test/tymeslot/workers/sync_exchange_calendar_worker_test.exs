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
  import Tymeslot.ExchangeSyncStubs
  import Tymeslot.Factory

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.ExchangeCase
  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Exchange.IntervalNormaliser
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncExchangeCalendarWorker

  @busy_start "2026-09-03T09:00:00Z"
  @busy_end "2026-09-03T10:00:00Z"
  @other_busy_start "2026-09-04T09:00:00Z"
  @other_busy_end "2026-09-04T10:00:00Z"

  @base_url "https://mail.example.com/EWS/Exchange.asmx"

  # How many failures open the host's breaker, read from the configuration so
  # a retuned provider retunes the tests below with it.
  @breaker_threshold CalendarCircuitBreaker.get_config(:exchange).failure_threshold

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    # Every EWS request runs through a per-host circuit breaker, so a test that
    # stubs a run of transport failures would otherwise leave the host's
    # breaker open and have the next test refused before it reached its stub.
    ExchangeCase.reset_breaker(@base_url)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: @base_url,
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

    test "keeps every free/busy request inside the window the service will accept", %{
      integration: integration
    } do
      # The sync window is 365 days each way; the Availability service refuses
      # a `TimeWindow` longer than its `MaximumQueryIntervalDays`, 42 by
      # default, with an error response code. Asking for the whole window in
      # one request therefore fails the busy read, and the worker writes
      # neither half of the cache: a connected mailbox with an empty cache
      # reads as a free diary. This pins the worker's own window against the
      # cap, where `Exchange.AvailabilityWindowTest` pins the slicing itself.
      stub_full_sync()

      assert :ok = run(integration)

      windows =
        sent_requests()
        |> Enum.filter(&(&1 =~ "<m:GetUserAvailabilityRequest"))
        |> Enum.map(&ExchangeCase.requested_availability_window/1)

      assert windows != []
      assert Enum.reject(windows, fn {from, to} -> DateTime.diff(to, from, :day) <= 42 end) == []
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

      # The guard lives on the full windowed read, which replaces the role's
      # rows wholesale; the incremental read never replaces anything, so it has
      # nothing to empty. Ageing the integration is what forces the full read
      # the guard belongs to.
      age_last_full_sync(integration)
      stub_full_sync(find_item: ExchangeFixtures.empty_find_item_response())

      assert {:error, {:empty_result_with_populated_cache, "display_only"}} = run(integration)

      assert [_item] = grid_rows(integration)
    end

    test "an empty free/busy response does not stop the grid half being judged on its own", %{
      integration: integration
    } do
      # Nothing cached yet, so an empty mailbox is believable and both halves
      # are written empty rather than refused.
      stub_full_sync(intervals: [], find_item: ExchangeFixtures.empty_find_item_response())

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

    test "snoozes rather than calling a server its breaker has already given up on", %{
      integration: integration
    } do
      ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, :econnrefused) end)

      # Each of these reaches the server and fails there, which is what opens
      # the host's breaker.
      for _attempt <- 1..@breaker_threshold do
        assert {:error, :network_error} = run(integration)
      end

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, :request_issued)
        ReqTest.transport_error(conn, :econnrefused)
      end)

      assert {:snooze, _seconds} = run(integration)
      refute_received :request_issued

      # A refusal is not the mailbox's failure, so nothing new is put in front
      # of its owner.
      assert %{needs_reauth: false} = Repo.reload!(integration)
    end
  end

  describe "a failure between the two halves" do
    test "keeps the busy rows it wrote but advances neither the stamp nor the cache", %{
      user: user,
      integration: integration
    } do
      stamped_at = ~U[2026-01-01 00:00:00Z]

      integration =
        integration
        |> Changeset.change(last_external_sync_at: stamped_at)
        |> Repo.update!()

      cache_key = AvailabilityCache.booking_window_events_key(user.id)
      AvailabilityCache.put(cache_key, {:ok, :seeded})

      stub_busy_read_then_item_fault()

      assert {:error, {:soap_fault, message}} = run(integration)
      assert message =~ "ErrorInvalidIdMalformed"

      # The availability half really did land: this is the partial success the
      # worker's moduledoc is about, and without it the rest of the test would
      # be asserting about a run that wrote nothing.
      assert [_busy] = availability_events(integration)
      assert grid_rows(integration) == []

      # The contract: the run short-circuits, so the freshness stamp does not
      # move and the availability cache is left alone. The cost is a lagging
      # indicator, not a bookable slot: the booking-time conflict check reads
      # the busy rows above rather than anything this cache holds.
      reloaded = Repo.reload!(integration)
      assert reloaded.last_external_sync_at == stamped_at
      assert reloaded.sync_error =~ "rejected the request"

      assert AvailabilityCache.get_or_compute(cache_key, fn -> {:ok, :recomputed} end) ==
               {:ok, :seeded}
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

  defp availability_events(integration) do
    CalendarEventQueries.in_range([integration.id], {window_start(), window_end()})
  end

  defp iso(date, time) do
    date |> DateTime.new!(time, "Etc/UTC") |> DateTime.to_iso8601()
  end

  # The free/busy read succeeds and its rows are written; the item read that
  # follows is refused. The fault is deliberately one the breaker ignores, so
  # what the test observes is the worker's short-circuit rather than a refusal
  # arriving from somewhere else.
  defp stub_busy_read_then_item_fault do
    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, request_body, conn} = Conn.read_body(conn)

      {status, body} =
        if request_body =~ "<m:GetUserAvailabilityRequest" do
          {200, availability_response(request_body, [{@busy_start, @busy_end}])}
        else
          {500, ExchangeCase.fault_envelope("ErrorInvalidIdMalformed")}
        end

      conn
      |> Conn.put_resp_content_type("text/xml")
      |> Conn.resp(status, body)
    end)
  end
end
