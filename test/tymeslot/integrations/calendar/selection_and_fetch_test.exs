defmodule Tymeslot.Integrations.Calendar.SelectionAndFetchTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch

  defmodule FakeAPI do
    @spec list_primary_events(map(), DateTime.t(), DateTime.t()) :: {:ok, list(map())}
    def list_primary_events(integration, _start_time, _end_time) do
      send(get_pid(integration), :primary_called)
      {:ok, [%{"id" => "primary-event"}]}
    end

    @spec list_events(map(), String.t(), DateTime.t(), DateTime.t()) :: {:ok, list(map())}
    def list_events(integration, calendar_id, _start_time, _end_time) do
      send(get_pid(integration), {:listed_calendar, calendar_id})
      {:ok, [%{"id" => "event-#{calendar_id}"}]}
    end

    defp get_pid(%{test_pid: pid}) when is_pid(pid), do: pid
    defp get_pid(_), do: self()
  end

  describe "prepare_selected_params/2" do
    test "builds calendar paths and normalized calendar_list" do
      selected = ["/cal/work"]
      discovered = [%{"id" => "work", "path" => "/cal/work", "name" => "Work"}]

      params = Selection.prepare_selected_params(selected, discovered)

      assert params["calendar_paths"] == ["/cal/work"]
      assert [calendar] = params["calendar_list"]
      assert calendar["id"] == "work"
      assert calendar["path"] == "/cal/work"
      assert calendar["selected"] == true
    end
  end

  describe "update_calendar_selection/2" do
    test "rejects default booking calendars that are not selected" do
      integration = %{
        user_id: 1,
        id: 10,
        calendar_list: [
          %{"id" => "work", "selected" => false, "path" => "/cal/work"}
        ]
      }

      params = %{
        "selected_calendars" => [],
        "default_booking_calendar" => "work"
      }

      assert {:error, :invalid_default_calendar} ==
               Selection.update_calendar_selection(integration, params)
    end

    test "persists selected calendars and sets default when provided" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_list: [
            %{"id" => "work", "selected" => false, "path" => "/cal/work"},
            %{"id" => "team", "selected" => false, "path" => "/cal/team"}
          ]
        )

      params = %{
        "selected_calendars" => ["team"],
        "default_booking_calendar" => "team"
      }

      assert {:ok, updated} = Selection.update_calendar_selection(integration, params)
      assert updated.default_booking_calendar_id == "team"

      assert [{"team", true}, {"work", false}] =
               updated.calendar_list
               |> Enum.sort_by(& &1["id"])
               |> Enum.map(&{&1["id"], &1["selected"]})
    end
  end

  describe "MultiCalendarFetch.list_events_with_selection/4" do
    test "uses only calendars marked as selected" do
      integration = %{
        test_pid: self(),
        calendar_list: [
          %{"id" => "work", "selected" => true},
          %{"id" => "personal", "selected" => false}
        ]
      }

      {:ok, events} =
        MultiCalendarFetch.list_events_with_selection(
          integration,
          DateTime.utc_now(),
          DateTime.add(DateTime.utc_now(), 3600, :second),
          FakeAPI
        )

      assert Enum.any?(events, &(&1["id"] == "event-work"))
      refute Enum.any?(events, &(&1["id"] == "event-personal"))
      assert_receive {:listed_calendar, "work"}
      refute_receive {:listed_calendar, "personal"}
    end

    test "falls back to primary events when no calendars are selected" do
      integration = %{calendar_list: []}

      {:ok, events} =
        MultiCalendarFetch.list_events_with_selection(
          integration,
          DateTime.utc_now(),
          DateTime.add(DateTime.utc_now(), 3600, :second),
          FakeAPI
        )

      assert Enum.any?(events, &(&1["id"] == "primary-event"))
      assert_receive :primary_called
    end

    test "deduplicates events by id across selected calendars" do
      integration = %{
        calendar_list: [
          %{"id" => "work", "selected" => true},
          %{"id" => "team", "selected" => true}
        ]
      }

      defmodule DuplicateAPI do
        @spec list_primary_events(map(), DateTime.t(), DateTime.t()) :: {:ok, list()}
        def list_primary_events(_integration, _start_time, _end_time), do: {:ok, []}

        @spec list_events(map(), String.t(), DateTime.t(), DateTime.t()) :: {:ok, list(map())}
        def list_events(_integration, _calendar_id, _start_time, _end_time),
          do: {:ok, [%{"id" => "same"}]}
      end

      {:ok, events} =
        MultiCalendarFetch.list_events_with_selection(
          integration,
          DateTime.utc_now(),
          DateTime.add(DateTime.utc_now(), 3600, :second),
          DuplicateAPI
        )

      assert events == [%{"id" => "same"}]
    end
  end
end
