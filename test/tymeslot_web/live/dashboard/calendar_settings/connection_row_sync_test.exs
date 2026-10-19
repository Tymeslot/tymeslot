defmodule TymeslotWeb.Dashboard.CalendarSettings.ConnectionRowSyncTest do
  @moduledoc """
  What a calendar's card says about its syncing, in the viewer's language:
  when it last synced, and the changes made here that its server kept
  refusing, with Retry offered only while the calendar is syncing.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias TymeslotWeb.Dashboard.CalendarSettings.Components

  @refused "The calendar server refused the request."

  setup do
    on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)
  end

  defp render_row(overrides, stuck \\ nil) do
    integration =
      Enum.into(overrides, %{
        id: 101,
        name: "Work CalDAV",
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        calendar_list: [%CalendarEntry{id: "/a/", path: "/a/", name: "A", selected: true}],
        calendar_paths: ["/a/"],
        base_url: "https://caldav.example.com",
        is_primary: false,
        default_booking_calendar_id: nil,
        provider_account_email: nil
      })

    render_component(&Components.calendar_connection_row/1,
      integration: integration,
      health_state: nil,
      stuck: stuck,
      myself: "target"
    )
  end

  defp retry_shown?(html), do: html =~ ~s(phx-click="retry_stuck_changes")

  describe "the stuck changes notice" do
    # The error is stored as the English msgid it was written with.
    test "translates the stored error into the viewer's language" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      html = render_row([], %{count: 2, last_error: @refused})

      assert html =~
               "2 hier vorgenommene Änderungen wurden nicht in diesem Kalender gespeichert. Letzter Fehler: Der Kalenderserver hat die Anfrage abgelehnt."

      refute html =~ @refused
    end

    test "offers Retry on a syncing calendar" do
      assert retry_shown?(render_row([], %{count: 1, last_error: @refused}))
    end

    # Nothing would replay the changes, so Retry would only reset them.
    test "does not offer Retry while the calendar waits to be reconnected or is paused" do
      refute retry_shown?(render_row([needs_reauth: true], %{count: 1, last_error: @refused}))
      refute retry_shown?(render_row([is_active: false], %{count: 1, last_error: @refused}))
    end

    test "offers no Retry when nothing is stuck" do
      refute retry_shown?(render_row([]))
    end
  end

  describe "the last sync" do
    test "is told in the viewer's language" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      synced_at = DateTime.add(DateTime.utc_now(), -5 * 60, :second)

      html = render_row(last_external_sync_at: synced_at)

      assert html =~ "Zuletzt synchronisiert vor 5 Minuten"
      refute html =~ "ago"
      refute html =~ "minutes"
    end

    test "counts in the largest whole unit" do
      for {seconds_ago, phrase} <- [
            {10, "Last synced just now"},
            {60, "Last synced 1 minute ago"},
            {2 * 3600, "Last synced 2 hours ago"},
            {3 * 86_400, "Last synced 3 days ago"}
          ] do
        html =
          render_row(
            last_external_sync_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
          )

        assert html =~ phrase
      end
    end
  end
end
