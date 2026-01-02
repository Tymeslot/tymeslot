defmodule Tymeslot.Integrations.Calendar.EventsReadTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Calendar.EventsRead

  @base_time ~U[2024-01-01 12:00:00Z]

  defmodule SuccessfulProvider do
    @spec get_events(any(), DateTime.t(), DateTime.t()) :: {:ok, list(map())}
    def get_events(_client, _start_time, _end_time) do
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

    @spec get_events(any()) :: {:ok, list(map())}
    def get_events(_client) do
      get_events(nil, ~U[2024-01-01 12:00:00Z], ~U[2024-01-01 13:00:00Z])
    end
  end

  defmodule FallbackProvider do
    @spec get_events(any(), DateTime.t(), DateTime.t()) :: {:error, :forced_failure}
    def get_events(_client, _start_time, _end_time), do: {:error, :forced_failure}

    @spec get_events(any()) :: {:ok, list(map())}
    def get_events(_client) do
      now = ~U[2024-01-01 12:00:00Z]
      early = DateTime.add(now, -86_400, :second)

      {:ok,
       [
         %{uid: "keep", start_time: now, end_time: DateTime.add(now, 3600, :second)},
         %{uid: "filtered", start_time: early, end_time: early}
       ]}
    end
  end

  defmodule ErroringProvider do
    @spec get_events(any(), DateTime.t(), DateTime.t()) :: {:error, :fail}
    def get_events(_client, _start_time, _end_time), do: {:error, :fail}

    @spec get_events(any()) :: {:error, :fail}
    def get_events(_client), do: {:error, :fail}
  end

  defmodule PartialEventsProvider do
    @spec get_events(any(), DateTime.t(), DateTime.t()) :: {:error, :trigger_fallback}
    def get_events(_client, _start_time, _end_time), do: {:error, :trigger_fallback}

    @spec get_events(any()) :: {:ok, list(map())}
    def get_events(_client) do
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
    end
  end

  defmodule OverlapProvider do
    @spec get_events(any(), DateTime.t(), DateTime.t()) :: {:error, :fallback}
    def get_events(_client, _start, _end), do: {:error, :fallback}

    @spec get_events(any()) :: {:ok, list(map())}
    def get_events(_client) do
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
