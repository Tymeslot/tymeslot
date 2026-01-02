defmodule Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetchTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch

  # Mock API module for testing
  defmodule MockAPI do
    @spec list_primary_events(any(), any(), any()) :: {:ok, list()}
    def list_primary_events(_integration, _start_time, _end_time) do
      {:ok,
       [
         %{"id" => "primary-1", "summary" => "Primary Event 1"},
         %{"id" => "primary-2", "summary" => "Primary Event 2"}
       ]}
    end

    @spec list_events(any(), any(), any(), any()) :: {:ok, list()}
    def list_events(_integration, calendar_id, _start_time, _end_time) do
      {:ok,
       [
         %{"id" => "#{calendar_id}-1", "summary" => "Event 1 from #{calendar_id}"},
         %{"id" => "#{calendar_id}-2", "summary" => "Event 2 from #{calendar_id}"}
       ]}
    end
  end

  defmodule FailingAPI do
    @spec list_primary_events(any(), any(), any()) :: {:error, atom()}
    def list_primary_events(_integration, _start_time, _end_time) do
      {:error, :network_error}
    end

    @spec list_events(any(), any(), any(), any()) :: {:error, atom()}
    def list_events(_integration, _calendar_id, _start_time, _end_time) do
      {:error, :timeout}
    end
  end

  describe "get_selected_calendars/1" do
    test "returns calendars with selected=true and valid id" do
      integration = %{
        calendar_list: [
          %{"id" => "cal1", "name" => "Personal", "selected" => true},
          %{"id" => "cal2", "name" => "Work", "selected" => false},
          %{"id" => "cal3", "name" => "Family", "selected" => true}
        ]
      }

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert length(selected) == 2
      assert Enum.any?(selected, fn cal -> cal["id"] == "cal1" end)
      assert Enum.any?(selected, fn cal -> cal["id"] == "cal3" end)
    end

    test "filters out calendars without id" do
      integration = %{
        calendar_list: [
          %{"name" => "No ID", "selected" => true},
          %{"id" => "cal1", "name" => "Has ID", "selected" => true}
        ]
      }

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert length(selected) == 1
      assert List.first(selected)["id"] == "cal1"
    end

    test "filters out calendars with selected=false" do
      integration = %{
        calendar_list: [
          %{"id" => "cal1", "selected" => false},
          %{"id" => "cal2", "selected" => true}
        ]
      }

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert length(selected) == 1
      assert List.first(selected)["id"] == "cal2"
    end

    test "returns empty list when no calendars selected" do
      integration = %{
        calendar_list: [
          %{"id" => "cal1", "selected" => false},
          %{"id" => "cal2", "selected" => false}
        ]
      }

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert selected == []
    end

    test "returns empty list when calendar_list is empty" do
      integration = %{calendar_list: []}

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert selected == []
    end

    test "returns empty list when integration has no calendar_list" do
      integration = %{}

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert selected == []
    end

    test "supports atom keys for calendar properties" do
      integration = %{
        calendar_list: [
          %{id: "cal1", name: "Personal", selected: true},
          %{id: "cal2", name: "Work", selected: false}
        ]
      }

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert length(selected) == 1
      assert List.first(selected)[:id] == "cal1"
    end

    test "supports mixed atom and string keys" do
      integration = %{
        calendar_list: [
          %{:id => "cal1", "selected" => true},
          %{"id" => "cal2", :selected => true}
        ]
      }

      selected = MultiCalendarFetch.get_selected_calendars(integration)

      assert length(selected) == 2
    end
  end

  describe "list_events_with_selection/4" do
    test "uses primary events when no calendars selected" do
      integration = %{calendar_list: []}

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      assert {:ok, events} =
               MultiCalendarFetch.list_events_with_selection(
                 integration,
                 start_time,
                 end_time,
                 MockAPI
               )

      assert length(events) == 2
      assert Enum.any?(events, fn e -> e["id"] == "primary-1" end)
    end

    test "fetches events from selected calendars in parallel" do
      integration = %{
        calendar_list: [
          %{"id" => "cal1", "selected" => true},
          %{"id" => "cal2", "selected" => true},
          %{"id" => "cal3", "selected" => true}
        ]
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      assert {:ok, events} =
               MultiCalendarFetch.list_events_with_selection(
                 integration,
                 start_time,
                 end_time,
                 MockAPI
               )

      # Should have events from all 3 calendars (2 events per calendar)
      assert length(events) == 6
      assert Enum.any?(events, fn e -> e["id"] == "cal1-1" end)
      assert Enum.any?(events, fn e -> e["id"] == "cal2-1" end)
      assert Enum.any?(events, fn e -> e["id"] == "cal3-1" end)
    end

    test "deduplicates events by id" do
      # Create a mock that returns duplicate events
      defmodule DuplicateAPI do
        @spec list_events(any(), any(), any(), any()) :: {:ok, list()}
        def list_events(_integration, _calendar_id, _start_time, _end_time) do
          {:ok,
           [
             %{"id" => "duplicate-1", "summary" => "Event 1"},
             %{"id" => "duplicate-2", "summary" => "Event 2"}
           ]}
        end
      end

      integration = %{
        calendar_list: [
          %{"id" => "cal1", "selected" => true},
          %{"id" => "cal2", "selected" => true}
        ]
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      assert {:ok, events} =
               MultiCalendarFetch.list_events_with_selection(
                 integration,
                 start_time,
                 end_time,
                 DuplicateAPI
               )

      # Should deduplicate events with same id
      ids = Enum.map(events, fn e -> e["id"] end)
      assert length(ids) == length(Enum.uniq(ids))
    end

    test "handles API errors gracefully" do
      integration = %{
        calendar_list: [
          %{"id" => "cal1", "selected" => true},
          %{"id" => "cal2", "selected" => true}
        ]
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      assert {:ok, events} =
               MultiCalendarFetch.list_events_with_selection(
                 integration,
                 start_time,
                 end_time,
                 FailingAPI
               )

      # Should return empty list when all requests fail
      assert events == []
    end

    test "includes successful results even when some fail" do
      # Create a mock that fails for specific calendars
      defmodule PartialFailAPI do
        @spec list_events(any(), binary(), any(), any()) :: {:error, atom()} | {:ok, list()}
        def list_events(_integration, "failing_cal", _start_time, _end_time) do
          {:error, :network_error}
        end

        @spec list_events(any(), any(), any(), any()) :: {:ok, list()}
        def list_events(_integration, calendar_id, _start_time, _end_time) do
          {:ok, [%{"id" => "#{calendar_id}-1", "summary" => "Event"}]}
        end
      end

      integration = %{
        calendar_list: [
          %{"id" => "cal1", "selected" => true},
          %{"id" => "failing_cal", "selected" => true},
          %{"id" => "cal2", "selected" => true}
        ]
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      assert {:ok, events} =
               MultiCalendarFetch.list_events_with_selection(
                 integration,
                 start_time,
                 end_time,
                 PartialFailAPI
               )

      # Should have events from successful calendars only
      assert length(events) == 2
      assert Enum.any?(events, fn e -> e["id"] == "cal1-1" end)
      assert Enum.any?(events, fn e -> e["id"] == "cal2-1" end)
    end

    test "respects max concurrency limit" do
      # Create integration with many calendars
      calendar_list =
        for i <- 1..30 do
          %{"id" => "cal#{i}", "selected" => true}
        end

      integration = %{calendar_list: calendar_list}

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      # Should complete without errors despite high concurrency
      assert {:ok, events} =
               MultiCalendarFetch.list_events_with_selection(
                 integration,
                 start_time,
                 end_time,
                 MockAPI
               )

      # Should have events from all calendars
      assert length(events) == 60
    end

    test "uses atom keys for calendar id access" do
      integration = %{
        calendar_list: [
          %{id: "cal1", selected: true}
        ]
      }

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600, :second)

      assert {:ok, events} =
               MultiCalendarFetch.list_events_with_selection(
                 integration,
                 start_time,
                 end_time,
                 MockAPI
               )

      assert length(events) == 2
    end
  end
end
