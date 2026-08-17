defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineMoveCorrectionTest do
  @moduledoc """
  The correction lines reaching the placeholder the provider is handed.

  `MoveCorrection` builds the pair; this is the assertion that it arrives. The
  distinction matters here more than usual: the mirror row would look identical
  either way, and a version that computed the lines correctly and dropped them
  on the way into the payload would leave the moved occurrence blocking the
  wrong slot while every row-level check passed. That is the failure the
  recurrence suite's moduledoc already names for the RRULE, and it applies
  unchanged to these lines.

  So every assertion here is on the payload handed to the provider.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    context = linked_pair()
    {:ok, link} = CalendarSyncLinkQueries.get(context.link.id)
    %{context | link: link}
  end

  defp weekly_instance(source) do
    %ProviderCalendarEventSchema{
      uid: "weekly-series@google.com",
      calendar_integration_id: source.id,
      provider: "google",
      provider_calendar_id: "primary",
      provider_event_id: "master_abc123_20261215T090000Z",
      summary: "Weekly standup",
      transparency: "opaque",
      status: "confirmed",
      all_day: false,
      timezone: "Europe/Tallinn",
      start_at: ~U[2026-12-15 09:00:00Z],
      end_at: ~U[2026-12-15 09:30:00Z],
      recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
      recurring_event_id: "master_abc123"
    }
  end

  defp expect_master(exdates \\ []) do
    expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
      assert event_id == "master_abc123"

      {:ok,
       %{
         "id" => "master_abc123",
         "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=TU"] ++ exdates,
         "start" => %{"dateTime" => "2026-03-03T09:00:00Z"},
         "end" => %{"dateTime" => "2026-03-03T09:30:00Z"}
       }}
    end)
  end

  describe "mirror/4 with moved occurrences" do
    test "the placeholder carries both correction lines alongside the rule", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master()

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-pid-1"}}
      end)

      moves = [
        %{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 22:00:00Z]}
      ]

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id, moved: moves)

      assert_received {:payload, payload}

      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"

      # The series' own zone, so the block lands where the organiser sees it.
      assert "EXDATE;TZID=Europe/Tallinn:20260814T170000" in payload.recurrence_exception_lines
      assert "RDATE;TZID=Europe/Tallinn:20260815T010000" in payload.recurrence_exception_lines
    end

    test "corrections are added to the master's own EXDATEs, not instead of them", %{
      user: user,
      source: source,
      link: link
    } do
      # A cancelled occurrence and a moved one on the same series. Replacing
      # rather than appending would silently un-cancel the cancelled one.
      expect_master(["EXDATE;TZID=Europe/Tallinn:20260901T120000"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-pid-1"}}
      end)

      moves = [
        %{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 22:00:00Z]}
      ]

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id, moved: moves)

      assert_received {:payload, payload}

      assert "EXDATE;TZID=Europe/Tallinn:20260901T120000" in payload.recurrence_exception_lines
      assert "EXDATE;TZID=Europe/Tallinn:20260814T170000" in payload.recurrence_exception_lines
      assert "RDATE;TZID=Europe/Tallinn:20260815T010000" in payload.recurrence_exception_lines
    end

    test "no moves leaves the payload exactly as it was", %{
      user: user,
      source: source,
      link: link
    } do
      # The regression that matters most: every series that has never had an
      # occurrence moved must produce byte-identical output to before.
      expect_master(["EXDATE;TZID=Europe/Tallinn:20260901T120000"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id, moved: [])

      assert_received {:payload, payload}

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20260901T120000"
             ]
    end

    test "a non-recurring source is unaffected by moves being passed", %{
      user: user,
      source: source,
      link: link
    } do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-pid-1"}}
      end)

      one_off = %{weekly_instance(source) | recurrence_rule: nil, recurring_event_id: nil}

      moves = [
        %{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 22:00:00Z]}
      ]

      assert :ok == Engine.mirror(link, one_off, user.id, moved: moves)

      assert_received {:payload, payload}

      refute Map.has_key?(payload, :recurrence_exception_lines)
      refute Map.has_key?(payload, :recurrence_rule)
    end
  end
end
