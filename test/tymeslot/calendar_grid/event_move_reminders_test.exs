defmodule Tymeslot.CalendarGrid.EventMoveRemindersTest do
  @moduledoc """
  A move writes the reminders the destination keeps
  (`CreateParams.fit_reminders/2`), and caches the same list, so the panel
  shows what the destination holds and a move back has nothing more to drop.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Test.CalendarGridHelpers

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Reminder

  setup :verify_on_exit!

  setup do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:created, payload})
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    stub(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

    user = insert(:user)

    source =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/src/"])

    %{user: user, source: source}
  end

  defp event_with(source, reminders) do
    insert_event(source, %{
      summary: "Planning",
      provider_calendar_id: "/src/",
      provider_event_id: "/src/planning.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      reminders: reminders
    })
  end

  defp move(user, event, integration),
    do: Changes.move_event(user.id, event, %{integration: integration, calendar_id: nil})

  defp alarms(reminders),
    do: Enum.map(reminders, &{Reminder.method(&1), Reminder.minutes_before(&1)})

  defp cached(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    row
  end

  test "a move to Outlook writes and caches the first reminder, as a notification", %{
    user: user,
    source: source
  } do
    outlook = insert(:calendar_integration, user: user, provider: "outlook")

    event =
      event_with(source, [
        %{"method" => "email", "minutes_before" => 10},
        %{"method" => "popup", "minutes_before" => 1440}
      ])

    refute Changes.keeps_reminders?(event, outlook)

    assert {:ok, %{uid: uid}} = move(user, event, outlook)

    assert_receive {:created, payload}
    assert alarms(payload.reminders) == [{:popup, 10}]

    row = cached(outlook, uid)
    assert alarms(row.reminders) == [{:popup, 10}]
    # Moved back, nothing more is lost.
    assert Changes.keeps_reminders?(row, source)
  end

  test "a move to Google sends no more reminders than Google keeps", %{
    user: user,
    source: source
  } do
    google = insert(:calendar_integration, user: user, provider: "google")
    reminders = for minutes <- 1..6, do: %{"method" => "popup", "minutes_before" => minutes}
    event = event_with(source, reminders)

    assert {:ok, %{uid: uid}} = move(user, event, google)

    assert_receive {:created, payload}
    expected = for minutes <- 1..5, do: {:popup, minutes}
    assert alarms(payload.reminders) == expected
    assert alarms(cached(google, uid).reminders) == expected
  end

  test "reminders the destination keeps are cached as they were", %{
    user: user,
    source: source
  } do
    google = insert(:calendar_integration, user: user, provider: "google")

    reminders = [
      %{"method" => "popup", "minutes_before" => 10},
      %{"method" => "email", "minutes_before" => 1440}
    ]

    event = event_with(source, reminders)
    assert Changes.keeps_reminders?(event, google)

    assert {:ok, %{uid: uid}} = move(user, event, google)

    assert_receive {:created, payload}
    assert payload.reminders == reminders
    assert cached(google, uid).reminders == reminders
  end

  test "a series keeps every reminder, copied as its provider holds it", %{
    user: user,
    source: source
  } do
    other = insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/o/"])
    reminders = for minutes <- 1..6, do: %{"method" => "popup", "minutes_before" => minutes}

    series =
      insert_event(source, %{
        summary: "Standup",
        provider_calendar_id: "/src/",
        provider_event_id: "/src/standup.ics",
        start_at: ~U[2026-06-01 09:00:00.000000Z],
        end_at: ~U[2026-06-01 09:15:00.000000Z],
        recurrence_rule: "FREQ=WEEKLY",
        reminders: reminders
      })

    assert Changes.keeps_reminders?(series, other)
    refute Changes.keeps_reminders?(event_with(source, reminders), other)
  end
end
