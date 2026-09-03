defmodule Tymeslot.Integrations.Calendar.Exchange.AvailabilityWindowTest do
  @moduledoc """
  Pins how `Exchange.Provider.list_busy_intervals/2` spends the window it is
  given.

  The Availability service refuses a `GetUserAvailability` `TimeWindow` longer
  than its `MaximumQueryIntervalDays` (42 by default) with an error response
  code, and the sync window is 730 days, so the read is sliced. That refusal
  is not a cosmetic one: the sync worker runs the busy read first and writes
  nothing when it fails, so a mailbox whose availability read is refused keeps
  an empty cache and its owner's diary reads as free while the dashboard shows
  the integration connected.

  Its own module rather than another `describe` in `ProviderTest`, which is at
  the line limit, and because these tests are about the request plan rather
  than about any one response.
  """

  # `async: false`: the case template swaps the HTTP client module in the
  # application environment, which every concurrently running test shares.
  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Integrations.Calendar.Exchange.Provider

  # Microsoft's conservative floor, restated here rather than read from the
  # provider: a test that took the cap from the code under test would follow
  # it anywhere, including past a limit a real server enforces.
  @cap_days 42

  describe "list_busy_intervals/2 window slicing" do
    test "leaves a window inside the cap as a single request" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        respond(conn, ExchangeFixtures.availability_response())
      end)

      assert {:ok, [_interval]} =
               Provider.list_busy_intervals(config(), range(~U[2026-10-01 00:00:00Z]))

      assert :counters.get(counter, 1) == 1
    end

    test "slices a window past the cap into requests that tile it exactly" do
      # Ninety-one days: two full slices and a remainder, enough to pin the
      # cap, the contiguity and the concatenation at once.
      {:ok, recorder} = Agent.start_link(fn -> [] end)

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        {start_at, _end_at} = window = requested_availability_window(body)
        Agent.update(recorder, &(&1 ++ [window]))

        # The answer is derived from the request, so the intervals asserted on
        # below observe which windows were actually asked for rather than a
        # canned fixture that would come back whatever was sent.
        respond(conn, busy_hour_at(start_at))
      end)

      assert {:ok, intervals} =
               Provider.list_busy_intervals(config(), range(~U[2026-12-01 00:00:00Z]))

      windows = Agent.get(recorder, & &1)

      # Half-open and consecutive: each slice starts where the last ended, the
      # first at the caller's start and the last at the caller's end, so no
      # stretch of the window goes unread and none is read twice.
      assert windows == [
               {~U[2026-09-01 00:00:00Z], ~U[2026-10-13 00:00:00Z]},
               {~U[2026-10-13 00:00:00Z], ~U[2026-11-24 00:00:00Z]},
               {~U[2026-11-24 00:00:00Z], ~U[2026-12-01 00:00:00Z]}
             ]

      # Stated apart from the literals above, because the cap is the invariant
      # and the tiling is only one consequence of it.
      assert Enum.reject(windows, &within_cap?/1) == []

      # Every slice's busy time survives into the answer, in the order read.
      assert Enum.map(intervals, & &1.start_at) == [
               ~U[2026-09-01 00:00:00Z],
               ~U[2026-10-13 00:00:00Z],
               ~U[2026-11-24 00:00:00Z]
             ]
    end

    test "reads the whole sync window in slices the service will accept" do
      # The window the sync worker actually asks for: 365 days each way.
      # Nothing here may exceed the cap, and the slices must still meet.
      {:ok, recorder} = Agent.start_link(fn -> [] end)

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        Agent.update(recorder, &(&1 ++ [requested_availability_window(body)]))
        respond(conn, ExchangeFixtures.availability_response())
      end)

      from = DateTime.add(~U[2026-09-01 00:00:00Z], -365, :day)
      to = DateTime.add(~U[2026-09-01 00:00:00Z], 365, :day)

      assert {:ok, _intervals} =
               Provider.list_busy_intervals(config(), start_time: from, end_time: to)

      windows = Agent.get(recorder, & &1)

      assert Enum.reject(windows, &within_cap?/1) == []
      assert Enum.reject(Enum.chunk_every(windows, 2, 1, :discard), &contiguous?/1) == []
      assert {^from, _first_end} = hd(windows)
      assert {_last_start, ^to} = List.last(windows)
    end

    test "fails the whole read when a later slice fails, rather than answering the earlier ones" do
      # Half a mailbox's busy time is a diary that reads as free for the rest
      # of the window, so the first refusal ends the read with its own error
      # term and the slices past it are never requested.
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          3 -> respond(conn, ExchangeFixtures.empty_availability_response())
          _other -> respond(conn, ExchangeFixtures.availability_response())
        end
      end)

      # Six months is five slices, so a halt on the third is visible.
      assert {:error, :no_response_code} =
               Provider.list_busy_intervals(config(), range(~U[2027-03-01 00:00:00Z]))

      assert :counters.get(counter, 1) == 3
    end

    test "fails the whole read when a later slice fails at the transport" do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          2 -> Conn.resp(conn, 403, "")
          _other -> respond(conn, ExchangeFixtures.availability_response())
        end
      end)

      assert {:error, :forbidden} =
               Provider.list_busy_intervals(config(), range(~U[2026-12-01 00:00:00Z]))

      assert :counters.get(counter, 1) == 2
    end
  end

  defp range(end_time), do: [start_time: ~U[2026-09-01 00:00:00Z], end_time: end_time]

  defp respond(conn, body) do
    conn
    |> Conn.put_resp_content_type("text/xml")
    |> Conn.resp(200, body)
  end

  # An availability response carrying one busy hour at the requested window's
  # own start.
  defp busy_hour_at(start_at) do
    ExchangeFixtures.availability_response([
      {DateTime.to_iso8601(start_at), start_at |> DateTime.add(1, :hour) |> DateTime.to_iso8601()}
    ])
  end

  defp within_cap?({start_at, end_at}), do: DateTime.diff(end_at, start_at, :day) <= @cap_days

  defp contiguous?([{_start, end_at}, {next_start, _next_end}]), do: end_at == next_start
end
