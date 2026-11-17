defmodule Tymeslot.CalendarGrid.EventEditOutlookShowAsTest do
  @moduledoc """
  An Outlook event keeps its own free/busy state through an edit from the
  calendar: the sync stores Graph's `showAs` with the event, an edit that
  leaves free/busy alone writes that state back (`oof`, `tentative`,
  `workingElsewhere`), and an edit that changes it writes `free` or `busy`.

  The runtime is real down to the Graph API module, which is mocked
  (`OutlookCalendarAPIMock`); each body it is handed goes through the real
  `Outlook.EventMapper`, so what is pinned is what Graph would receive.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper
  alias Tymeslot.Integrations.Calendar.Outlook.EventNormaliser
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)
    on_exit(fn -> Application.put_env(:tymeslot, :calendar_module, previous) end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "outlook",
        access_token_encrypted: Encryption.encrypt("valid_token"),
        refresh_token_encrypted: Encryption.encrypt("refresh_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

    %{user: user, integration: integration}
  end

  # The event as the Outlook sync caches it from Graph's answer.
  defp synced_row(integration, show_as) do
    raw = %{
      "id" => "AAMk-#{show_as}",
      "iCalUId" => "ical-#{show_as}-#{System.unique_integer([:positive])}",
      "subject" => "Away",
      "body" => %{"content" => ""},
      "location" => %{"displayName" => ""},
      "showAs" => show_as,
      "isAllDay" => false,
      "isCancelled" => false,
      "start" => %{"dateTime" => "2026-06-01T09:00:00Z", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-06-01T17:00:00Z", "timeZone" => "UTC"},
      "attendees" => []
    }

    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: "outlook-calendar-1",
      synced_at: DateTime.utc_now()
    }

    {:ok, [event]} = EventNormaliser.normalise_events([raw], context)

    {:ok, 1} =
      ProviderCalendarEventQueries.upsert_batch([
        ProviderCalendarEventSchema.from_calendar_event(event)
      ])

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
    row
  end

  # Answers the write and sends the test the body Graph would be sent.
  defp expect_graph_update do
    test_pid = self()

    expect(OutlookCalendarAPIMock, :update_event, fn _integration,
                                                     "outlook-calendar-1",
                                                     _id,
                                                     attrs ->
      {:ok, body} = EventMapper.format_event_data(attrs)
      send(test_pid, {:graph_body, body})
      {:ok, %{"id" => "AAMk"}}
    end)
  end

  defp graph_body do
    assert_received {:graph_body, body}
    body
  end

  test "the sync keeps Graph's own state with the cached event, as busy", %{
    integration: integration
  } do
    row = synced_row(integration, "oof")

    assert row.transparency == "opaque"
    assert row.provider_metadata["showAs"] == "oof"
  end

  for show_as <- ~w(oof tentative workingElsewhere) do
    test "a rename of a #{show_as} event writes #{show_as} back", %{
      user: user,
      integration: integration
    } do
      row = synced_row(integration, unquote(show_as))
      expect_graph_update()

      assert {:ok, _updated} = Changes.update_event(user.id, row, %{summary: "Away, back Monday"})

      assert graph_body()["showAs"] == unquote(show_as)
    end
  end

  test "setting an out-of-office event free writes free", %{user: user, integration: integration} do
    row = synced_row(integration, "oof")
    expect_graph_update()

    assert {:ok, _updated} = Changes.update_event(user.id, row, %{transparency: "transparent"})

    assert graph_body()["showAs"] == "free"
  end

  test "setting a free event busy writes busy", %{user: user, integration: integration} do
    row = synced_row(integration, "free")
    expect_graph_update()

    assert {:ok, _updated} = Changes.update_event(user.id, row, %{transparency: "opaque"})

    assert graph_body()["showAs"] == "busy"
  end

  test "busy set on an event made free before the next sync writes busy, not the old state", %{
    user: user,
    integration: integration
  } do
    row = synced_row(integration, "oof")
    expect_graph_update()
    expect_graph_update()

    assert {:ok, free} = Changes.update_event(user.id, row, %{transparency: "transparent"})
    assert graph_body()["showAs"] == "free"

    assert {:ok, _busy} = Changes.update_event(user.id, free, %{transparency: "opaque"})
    assert graph_body()["showAs"] == "busy"
  end

  test "a rename after oof, free, busy before the next sync writes busy", %{
    user: user,
    integration: integration
  } do
    row = synced_row(integration, "oof")
    expect_graph_update()
    expect_graph_update()
    expect_graph_update()

    assert {:ok, free} = Changes.update_event(user.id, row, %{transparency: "transparent"})
    assert {:ok, busy} = Changes.update_event(user.id, free, %{transparency: "opaque"})
    assert graph_body()["showAs"] == "free"
    assert graph_body()["showAs"] == "busy"

    assert {:ok, _renamed} = Changes.update_event(user.id, busy, %{summary: "Away, back Monday"})
    assert graph_body()["showAs"] == "busy"
  end
end
