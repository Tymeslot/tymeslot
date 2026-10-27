defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventTimingTest do
  @moduledoc """
  The cache's timing columns are all nullable, so each writer that does not go
  through `CalendarEvent.new/1` checks the row's timing itself: a timed row
  needs both instants and an all-day row both dates, or the grid has nowhere
  to place it.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import ExUnit.CaptureLog
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup do
    %{integration: insert(:calendar_integration)}
  end

  defp timed_attrs(integration, overrides) do
    start_at = ~U[2027-02-22 10:00:00.000000Z]

    Map.merge(
      %{
        uid: "timing-#{System.unique_integer([:positive])}",
        calendar_integration_id: integration.id,
        provider: "google",
        provider_calendar_id: "primary",
        all_day: false,
        start_at: start_at,
        end_at: DateTime.add(start_at, 1, :hour),
        synced_at: ~U[2027-02-22 09:00:00.000000Z]
      },
      overrides
    )
  end

  describe "upsert_batch/1" do
    test "leaves out a timed row without an end, and stores the rest", %{integration: i} do
      good = timed_attrs(i, %{})
      half = timed_attrs(i, %{end_at: nil})

      log =
        capture_log(fn ->
          assert {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([good, half])
        end)

      assert log =~ "Not caching a calendar event with incomplete timing"
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(i.id, good.uid)
      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(i.id, half.uid)
    end

    test "leaves out an all-day row without an end date", %{integration: i} do
      half =
        timed_attrs(i, %{all_day: true, start_at: nil, end_at: nil, start_date: ~D[2027-02-22]})

      capture_log(fn -> assert {:ok, 0} = ProviderCalendarEventQueries.upsert_batch([half]) end)

      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(i.id, half.uid)
    end

    # Some all-day writers also carry the instants their dates came from; the
    # dates are what an all-day row is placed by, so the row is kept.
    test "stores an all-day row whose start and end instants are also set", %{integration: i} do
      row =
        timed_attrs(i, %{
          all_day: true,
          start_date: ~D[2027-02-22],
          end_date: ~D[2027-02-23]
        })

      assert {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([row])
      assert {:ok, %{all_day: true}} = ProviderCalendarEventQueries.get_by_uid(i.id, row.uid)
    end
  end

  test "the dashboard's create path caches a timed event that leaves out all_day", %{
    integration: i
  } do
    row = Map.delete(timed_attrs(i, %{}), :all_day)

    CalendarGrid.cache_created_event(row)

    assert {:ok, %{all_day: false, end_at: %DateTime{}}} =
             ProviderCalendarEventQueries.get_by_uid(i.id, row.uid)
  end

  test "the dashboard's create path does not cache an event without an end", %{integration: i} do
    half = timed_attrs(i, %{end_at: nil})

    capture_log(fn -> CalendarGrid.cache_created_event(half) end)

    assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(i.id, half.uid)
  end

  test "update_after_outbound_push/2 refuses to clear an event's end", %{integration: i} do
    event = insert(:provider_calendar_event, calendar_integration: i)

    assert {:error, changeset} =
             ProviderCalendarEventQueries.update_after_outbound_push(event, %{end_at: nil})

    assert changeset.errors[:all_day]
  end

  test "apply_local_edit/3 refuses to clear an event's end", %{integration: i} do
    event = insert(:provider_calendar_event, calendar_integration: i)

    assert {:error, changeset} =
             ProviderCalendarEventQueries.apply_local_edit(i.id, event.uid, %{end_at: nil})

    assert changeset.errors[:all_day]

    assert {:ok, %{end_at: %DateTime{}}} =
             ProviderCalendarEventQueries.get_by_uid(i.id, event.uid)
  end

  test "search leaves out a stored row without an end", %{integration: i} do
    whole = insert(:provider_calendar_event, calendar_integration: i, summary: "Review")

    _half =
      insert(:provider_calendar_event, calendar_integration: i, summary: "Review", end_at: nil)

    capture_log(fn ->
      assert [%{id: id}] = CalendarGrid.search_events(i.user_id, "review", [i])
      assert id == whole.id
    end)
  end

  test "search fills its page past a stored row without an end", %{integration: i} do
    _half =
      insert(:provider_calendar_event,
        calendar_integration: i,
        summary: "Review",
        start_at: ~U[2027-02-22 09:00:00.000000Z],
        end_at: nil
      )

    whole =
      insert(:provider_calendar_event,
        calendar_integration: i,
        summary: "Review",
        start_at: ~U[2027-02-22 10:00:00.000000Z]
      )

    assert [%{id: id}] = CalendarGrid.search_events(i.user_id, "review", [i], limit: 1)
    assert id == whole.id
  end

  test "the grid skips a stored row without an end, and logs it", %{integration: i} do
    start_at = ~U[2027-02-22 10:00:00.000000Z]
    whole = insert(:provider_calendar_event, calendar_integration: i, start_at: start_at)

    # Stored before the writers checked timing: the factory, like `insert_all`,
    # runs no changeset.
    _half =
      insert(:provider_calendar_event, calendar_integration: i, start_at: start_at, end_at: nil)

    log =
      capture_log(fn ->
        events =
          CalendarGrid.list_events_for_range(
            [i.id],
            ~U[2027-02-22 00:00:00Z],
            ~U[2027-02-23 00:00:00Z]
          )

        assert Enum.map(events, & &1.id) == [whole.id]
      end)

    assert log =~ "Calendar grid skipped a cached event with incomplete timing"
  end
end
