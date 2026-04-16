defmodule Tymeslot.Integrations.Calendar.EventsReadTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.EventsRead

  @base_time ~U[2024-01-01 12:00:00Z]

  defmodule SuccessfulProvider do
    @spec list_events(any(), keyword()) :: {:ok, list(map())}
    def list_events(_client, _opts) do
      now = ~U[2024-01-01 12:00:00Z]

      {:ok,
       [
         %{
           uid: "event-1",
           summary: "Meeting 1",
           start_time: now,
           end_time: DateTime.add(now, 3600, :second)
         },
         %{
           uid: "event-2",
           summary: "Meeting 2",
           start_time: DateTime.add(now, 7200, :second),
           end_time: DateTime.add(now, 10_800, :second)
         }
       ]}
    end
  end

  # Simulates a provider that fails on narrow range queries but succeeds on wide-range
  # (fallback) queries — distinguished by the range duration in opts.
  defmodule FallbackProvider do
    @wide_range_days 300

    @spec list_events(any(), keyword()) ::
            {:ok, list(map())} | {:error, :forced_failure}
    def list_events(_client, opts) do
      start_time = opts[:start_time]
      end_time = opts[:end_time]

      range_days =
        if start_time && end_time do
          DateTime.diff(end_time, start_time, :day)
        else
          0
        end

      if range_days >= @wide_range_days do
        now = ~U[2024-01-01 12:00:00Z]
        early = DateTime.add(now, -86_400, :second)

        {:ok,
         [
           %{uid: "keep", start_time: now, end_time: DateTime.add(now, 3600, :second)},
           %{uid: "filtered", start_time: early, end_time: early}
         ]}
      else
        {:error, :forced_failure}
      end
    end
  end

  defmodule ErroringProvider do
    @spec list_events(any(), keyword()) :: {:error, :fail}
    def list_events(_client, _opts), do: {:error, :fail}
  end

  # Simulates a provider that fails on narrow range queries but succeeds on wide-range
  # (fallback) queries — returns partial events with missing fields on wide range.
  defmodule PartialEventsProvider do
    @wide_range_days 300

    @spec list_events(any(), keyword()) ::
            {:ok, list(map())} | {:error, :trigger_fallback}
    def list_events(_client, opts) do
      start_time = opts[:start_time]
      end_time = opts[:end_time]

      range_days =
        if start_time && end_time do
          DateTime.diff(end_time, start_time, :day)
        else
          0
        end

      if range_days >= @wide_range_days do
        now = ~U[2024-01-01 12:00:00Z]

        {:ok,
         [
           # Event with all required fields
           %{
             uid: "complete-event",
             start_time: now,
             end_time: DateTime.add(now, 3600, :second)
           },
           # Event missing start_time (should be filtered out in fallback)
           %{uid: "incomplete-1", end_time: DateTime.add(now, 3600, :second)},
           # Event missing end_time (should be filtered out in fallback)
           %{uid: "incomplete-2", start_time: now}
         ]}
      else
        {:error, :trigger_fallback}
      end
    end
  end

  # Simulates a provider that fails on narrow range queries but succeeds on wide-range
  # (fallback) queries — returns events with various overlap scenarios on wide range.
  defmodule OverlapProvider do
    @wide_range_days 300

    @spec list_events(any(), keyword()) ::
            {:ok, list(map())} | {:error, :fallback}
    def list_events(_client, opts) do
      start_time = opts[:start_time]
      end_time = opts[:end_time]

      range_days =
        if start_time && end_time do
          DateTime.diff(end_time, start_time, :day)
        else
          0
        end

      if range_days >= @wide_range_days do
        now = ~U[2024-01-01 12:00:00Z]

        {:ok,
         [
           # Ends exactly at start_time (should be excluded if exclusive)
           %{uid: "ends-at-start", start_time: DateTime.add(now, -3600), end_time: now},
           # Overlaps start boundary
           %{
             uid: "overlaps-start",
             start_time: DateTime.add(now, -1800),
             end_time: DateTime.add(now, 1800)
           },
           # Fully inside
           %{
             uid: "fully-inside",
             start_time: DateTime.add(now, 1800),
             end_time: DateTime.add(now, 3600)
           },
           # Overlaps end boundary
           %{
             uid: "overlaps-end",
             start_time: DateTime.add(now, 5400),
             end_time: DateTime.add(now, 9000)
           },
           # Starts exactly at end_time (should be excluded)
           %{
             uid: "starts-at-end",
             start_time: DateTime.add(now, 7200),
             end_time: DateTime.add(now, 10_800)
           }
         ]}
      else
        {:error, :fallback}
      end
    end
  end

  describe "fetch_events_with_fallback/3" do
    test "successfully fetches events when range query works" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: SuccessfulProvider,
        client: %{calendar_path: "/cal/success"}
      }

      start_dt = DateTime.add(@base_time, -3600, :second)
      end_dt = DateTime.add(@base_time, 7200, :second)

      assert {:ok, events, "/cal/success"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      assert length(events) == 2
      assert Enum.map(events, & &1.uid) == ["event-1", "event-2"]
    end

    test "uses full list fallback when range fetch fails and filters by range" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: FallbackProvider,
        client: %{calendar_path: "/cal/a"}
      }

      start_dt = DateTime.add(@base_time, -3600, :second)
      end_dt = DateTime.add(@base_time, 3600, :second)

      assert {:ok, events, "/cal/a"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      assert Enum.map(events, & &1.uid) == ["keep"]
    end

    test "returns error when both range fetch and fallback fail" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: ErroringProvider,
        client: %{calendar_path: "/cal/error"}
      }

      start_dt = DateTime.add(@base_time, -3600, :second)
      end_dt = DateTime.add(@base_time, 3600, :second)

      assert {:error, :fail, "/cal/error"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)
    end

    test "filters out events with missing start_time or end_time in fallback" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: PartialEventsProvider,
        client: %{calendar_path: "/cal/partial"}
      }

      start_dt = DateTime.add(@base_time, -3600, :second)
      end_dt = DateTime.add(@base_time, 7200, :second)

      assert {:ok, events, "/cal/partial"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      # Only "complete-event" should be returned because fallback filters missing fields
      assert length(events) == 1
      assert hd(events).uid == "complete-event"
    end

    test "includes events that overlap with the time range in fallback mode" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: OverlapProvider,
        client: %{calendar_path: "/cal/overlap"}
      }

      # Range: base_time to base_time + 7200s (2 hours)
      start_dt = @base_time
      end_dt = DateTime.add(@base_time, 7200, :second)

      assert {:ok, events, "/cal/overlap"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      uids = Enum.sort(Enum.map(events, & &1.uid))
      assert uids == ["fully-inside", "overlaps-end", "overlaps-start"]
      refute "ends-at-start" in uids
      refute "starts-at-end" in uids
    end

    test "extracts calendar path correctly from nested client structure" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: SuccessfulProvider,
        client: %{calendar_path: "/calendars/user123/home"}
      }

      start_dt = @base_time
      end_dt = DateTime.add(@base_time, 3600, :second)

      assert {:ok, _events, "/calendars/user123/home"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)
    end

    test "handles Date inputs correctly by converting to DateTime" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: SuccessfulProvider,
        client: %{calendar_path: "/cal/date"}
      }

      # These will be passed to list_events_in_range which uses ensure_utc
      start_date = ~D[2024-01-01]
      end_date = ~D[2024-01-02]

      # Call with injected client list
      assert {:ok, events} =
               EventsRead.list_events_in_range(start_date, end_date, fn -> [adapter_client] end)

      # SuccessfulProvider returns events for ~U[2024-01-01 12:00:00Z]
      # which is inside the range of ~D[2024-01-01] (00:00:00) to ~D[2024-01-02] (00:00:00)
      assert length(events) == 2
      assert Enum.any?(events, &(&1.uid == "event-1"))
    end
  end

  # Provider returning a recurring event (FREQ=DAILY;COUNT=5) starting on Jan 1.
  # The fresh-fetch path must expand this into individual occurrences within the
  # requested range, not return the master event alone.
  defmodule RecurringProvider do
    @spec list_events(any(), keyword()) :: {:ok, list(map())}
    def list_events(_client, _opts) do
      {:ok,
       [
         %{
           uid: "recurring-daily",
           summary: "Daily standup",
           start_time: ~U[2024-01-01 09:45:00Z],
           end_time: ~U[2024-01-01 10:00:00Z],
           recurrence_rule: "FREQ=DAILY;COUNT=5"
         },
         %{
           uid: "one-off",
           summary: "One-off meeting",
           start_time: ~U[2024-01-02 14:00:00Z],
           end_time: ~U[2024-01-02 15:00:00Z]
         }
       ]}
    end
  end

  # Provider returning a recurring event with an EXDATE that should be excluded.
  defmodule RecurringWithExdateProvider do
    @spec list_events(any(), keyword()) :: {:ok, list(map())}
    def list_events(_client, _opts) do
      {:ok,
       [
         %{
           uid: "recurring-with-exdate",
           summary: "Weekday standup",
           start_time: ~U[2024-01-01 09:45:00Z],
           end_time: ~U[2024-01-01 10:00:00Z],
           recurrence_rule: "FREQ=DAILY;COUNT=3",
           exdates: [~U[2024-01-02 09:45:00Z]]
         }
       ]}
    end
  end

  describe "recurring event expansion in fetch_events_with_fallback/3" do
    test "expands recurring events into individual occurrences" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: RecurringProvider,
        client: %{calendar_path: "/cal/recurring"}
      }

      # Range covers Jan 1-5 (all 5 occurrences of the daily event)
      start_dt = ~U[2024-01-01 00:00:00Z]
      end_dt = ~U[2024-01-06 00:00:00Z]

      assert {:ok, events, "/cal/recurring"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      # Should have 5 expanded occurrences + 1 one-off = 6 events
      assert length(events) == 6

      recurring_events = Enum.filter(events, &(&1.uid == "recurring-daily"))
      assert length(recurring_events) == 5

      # Each occurrence should have the correct start/end times shifted by day
      start_times =
        recurring_events
        |> Enum.map(& &1.start_time)
        |> Enum.sort(DateTime)

      assert start_times == [
               ~U[2024-01-01 09:45:00Z],
               ~U[2024-01-02 09:45:00Z],
               ~U[2024-01-03 09:45:00Z],
               ~U[2024-01-04 09:45:00Z],
               ~U[2024-01-05 09:45:00Z]
             ]

      # One-off event should be unchanged
      assert Enum.any?(events, &(&1.uid == "one-off"))
    end

    test "respects EXDATE exclusions during expansion" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: RecurringWithExdateProvider,
        client: %{calendar_path: "/cal/exdate"}
      }

      start_dt = ~U[2024-01-01 00:00:00Z]
      end_dt = ~U[2024-01-04 00:00:00Z]

      assert {:ok, events, "/cal/exdate"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      # COUNT=3 would give Jan 1, 2, 3 but Jan 2 is excluded by EXDATE
      assert length(events) == 2

      start_times =
        events
        |> Enum.map(& &1.start_time)
        |> Enum.sort(DateTime)

      assert start_times == [
               ~U[2024-01-01 09:45:00Z],
               ~U[2024-01-03 09:45:00Z]
             ]
    end

    test "only expands occurrences within the requested range" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: RecurringProvider,
        client: %{calendar_path: "/cal/partial-range"}
      }

      # Range only covers Jan 3-4 (should get 2 of the 5 daily occurrences)
      start_dt = ~U[2024-01-03 00:00:00Z]
      end_dt = ~U[2024-01-05 00:00:00Z]

      assert {:ok, events, "/cal/partial-range"} =
               EventsRead.fetch_events_with_fallback(adapter_client, start_dt, end_dt)

      recurring_events = Enum.filter(events, &(&1.uid == "recurring-daily"))
      assert length(recurring_events) == 2

      start_times =
        recurring_events
        |> Enum.map(& &1.start_time)
        |> Enum.sort(DateTime)

      assert start_times == [
               ~U[2024-01-03 09:45:00Z],
               ~U[2024-01-04 09:45:00Z]
             ]
    end
  end

  # Provider returning a recurring event relative to "now" so it falls within
  # the hardcoded range used by fetch_events_without_range (now-30d to now+365d).
  defmodule NowRelativeRecurringProvider do
    @spec list_events(any(), keyword()) :: {:ok, list(map())}
    def list_events(_client, _opts) do
      now = DateTime.utc_now()
      start = DateTime.add(now, -1, :day)

      {:ok,
       [
         %{
           uid: "recurring-now",
           summary: "Daily recurring",
           start_time: start,
           end_time: DateTime.add(start, 900, :second),
           recurrence_rule: "FREQ=DAILY;COUNT=3"
         }
       ]}
    end
  end

  describe "fetch_events_without_range/1" do
    test "successfully fetches all events without time range" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: SuccessfulProvider,
        client: %{calendar_path: "/cal/all"}
      }

      assert {:ok, events, "/cal/all"} = EventsRead.fetch_events_without_range(adapter_client)

      assert length(events) == 2
      assert Enum.all?(events, &Map.has_key?(&1, :uid))
    end

    test "expands recurring events within the default range" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: NowRelativeRecurringProvider,
        client: %{calendar_path: "/cal/recurring-no-range"}
      }

      assert {:ok, events, "/cal/recurring-no-range"} =
               EventsRead.fetch_events_without_range(adapter_client)

      # COUNT=3 starting yesterday — all 3 occurrences fall within now-30d..now+365d
      assert length(events) == 3

      recurring = Enum.filter(events, &(&1[:uid] == "recurring-now"))
      assert length(recurring) == 3
    end

    test "returns error tuple when provider fails" do
      adapter_client = %{
        provider_type: :fake,
        provider_module: ErroringProvider,
        client: %{calendar_path: "/cal/a"}
      }

      assert {:error, :fail, "/cal/a"} = EventsRead.fetch_events_without_range(adapter_client)
    end
  end
end
