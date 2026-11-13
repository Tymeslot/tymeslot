defmodule Tymeslot.CalendarGrid.EventEditTransparencyTest do
  @moduledoc """
  Free/busy (`transparency`) is an ordinary editable field: an edit writes
  it to the provider and to the cached row, a series edit carries it to the
  occurrence or the master, and anything but busy or free is refused before
  anything is written.

  The provider write is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`), as in `Tymeslot.CalendarGrid.EventEditTest`.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.Google.EventMapper, as: GoogleMapper
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google")

    %{user: user, integration: integration}
  end

  defp insert_event(integration, attrs \\ %{}) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Focus time",
      provider: "google",
      provider_calendar_id: "team-calendar",
      provider_event_id: "focus-time",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      transparency: "opaque",
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp expect_provider_update(result \\ :ok) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn uid, payload, context ->
      send(test_pid, {:provider_update, uid, payload, context})
      result
    end)
  end

  defp captured_payload do
    assert_received {:provider_update, _uid, payload, _context}
    payload
  end

  describe "a one-off event" do
    test "set to free is written as transparent, and the cached row follows", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration)
      expect_provider_update()

      assert {:ok, updated} = Changes.update_event(user.id, event, %{transparency: "transparent"})
      assert updated.transparency == "transparent"

      payload = captured_payload()
      assert payload.transparency == "transparent"
      assert GoogleMapper.format_event_data(payload)["transparency"] == "transparent"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.transparency == "transparent"
    end

    test "set back to busy is written as opaque", %{user: user, integration: integration} do
      event = insert_event(integration, %{transparency: "transparent"})
      expect_provider_update()

      assert {:ok, _updated} = Changes.update_event(user.id, event, %{transparency: "opaque"})

      assert captured_payload().transparency == "opaque"
      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.transparency == "opaque"
    end

    test "an unrelated edit keeps what the row says", %{user: user, integration: integration} do
      event = insert_event(integration, %{transparency: "transparent"})
      expect_provider_update()

      assert {:ok, _updated} = Changes.update_event(user.id, event, %{summary: "Deep work"})

      assert captured_payload().transparency == "transparent"
      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert {row.summary, row.transparency} == {"Deep work", "transparent"}
    end

    test "a value other than busy or free raises before anything is written", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration)

      assert_raise ArgumentError, ~r/transparency must be one of/, fn ->
        Changes.update_event(user.id, event, %{transparency: "tentative"})
      end

      assert_raise ArgumentError, ~r/transparency must be one of/, fn ->
        Changes.update_event(user.id, event, %{transparency: :transparent})
      end
    end
  end

  describe "a member of a series" do
    test "free for all events is sent to the master as that change alone", %{
      user: user,
      integration: integration
    } do
      event =
        insert_event(integration, %{
          provider_event_id: "series-1_20260601T090000Z",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
          recurring_event_id: "series-1"
        })

      expect_provider_update()

      assert {:ok, _updated} =
               Changes.update_event(user.id, event, %{transparency: "transparent"},
                 recurrence_scope: :all
               )

      assert %{scope: :all, master_id: "series-1", changes: changes} =
               captured_payload().occurrence

      assert changes == %{transparency: "transparent"}
    end

    test "free for one CalDAV occurrence is written into its override", %{user: user} do
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event =
        insert_event(caldav, %{
          uid: "weekly-sync_20260601T090000",
          provider: "caldav",
          provider_event_id: "/cal/weekly-sync.ics",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
          recurring_event_id: nil,
          provider_metadata: %{"uid" => "weekly-sync"}
        })

      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      assert {:ok, _updated} =
               Changes.update_event(user.id, event, %{transparency: "transparent"},
                 recurrence_scope: :this_only
               )

      assert %{key: "20260601T090000", changes: %{transparency: "transparent"}} =
               captured_payload().occurrence

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert row.transparency == "transparent"
    end
  end

  describe "a booking's calendar copy" do
    # Its Busy/Free follows the meeting type's "show as free" setting, so the
    # domain refuses a change whatever the caller drew. No provider write is
    # expected: `verify_on_exit!` fails the test if one is made.
    setup %{user: user, integration: integration} do
      event = insert_event(integration, %{uid: "booked-copy"})

      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "booked-copy"
      )

      %{event: event}
    end

    test "refuses a change of Busy/Free before anything is written", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:error, %{reason: :booking, retry: :not_queued}} =
               Changes.update_event(user.id, event, %{transparency: "transparent"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.transparency == "opaque"
    end

    test "still takes a change that leaves Busy/Free alone", %{user: user, event: event} do
      expect_provider_update()

      assert {:ok, updated} = Changes.update_event(user.id, event, %{summary: "Booked call"})
      assert updated.summary == "Booked call"
    end
  end

  describe "a member of a booked series" do
    test "refuses a change of Busy/Free to all its events", %{
      user: user,
      integration: integration
    } do
      member =
        insert_event(integration, %{
          uid: "booked-series",
          provider_event_id: "booked-series_20260601T090000Z",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
          recurring_event_id: "booked-series"
        })

      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "booked-series"
      )

      assert {:error, %{reason: :booking, retry: :not_queued}} =
               Changes.update_event(user.id, member, %{transparency: "transparent"},
                 recurrence_scope: :all
               )

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, member.uid)
      assert row.transparency == "opaque"
    end
  end
end
