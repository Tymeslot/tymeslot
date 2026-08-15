defmodule TymeslotWeb.Dashboard.CalendarGrid.MirrorHidingTest do
  @moduledoc """
  Busy-block mirrors are kept out of the organiser's own calendar grid.

  A mirror is a placeholder Tymeslot writes onto a second calendar so that
  external tools reading that calendar see the time as taken. Drawing it in the
  organiser's own grid would show every synchronised event twice, side by side
  with its source.

  Asserted through the LiveView rather than against `mirror_uids_for_integrations/1`,
  which `calendar_sync_mirror_queries_test.exs` already covers: what only the
  rendered grid can show is that the set reaches the filter at all, and that the
  filter picks the mirror rather than everything Tymeslot happens to have written.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Appearance

  setup :setup_dashboard_user

  setup %{user: user} do
    source = insert(:calendar_integration, user: user, is_active: true, name: "Work")
    target = insert(:calendar_integration, user: user, is_active: true, name: "Personal")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    {:ok, source: source, target: target, link: link}
  end

  defp at(time), do: DateTime.new!(Date.utc_today(), time, "Etc/UTC")

  defp insert_event(integration, summary, time, overrides) do
    attrs =
      Keyword.merge(
        [
          calendar_integration: integration,
          summary: summary,
          start_at: at(time),
          end_at: DateTime.add(at(time), 3600)
        ],
        overrides
      )

    insert(:provider_calendar_event, attrs)
  end

  describe "a mirror on one of the organiser's own calendars" do
    test "is left out of the grid, while a booking Tymeslot created stays in it", %{
      conn: conn,
      source: source,
      target: target,
      link: link
    } do
      # The two events below differ only in whether a mirror row points at them.
      # Both carry `created_by_tymeslot: true`, because both were written by
      # Tymeslot — that flag says who wrote the event, not what kind it is. A
      # filter keyed on it would take the organiser's booking off their own
      # calendar, so the second assertion is the one that catches it.
      insert_event(target, "Busy", ~T[10:00:00],
        uid: "mirror-uid-1",
        created_by_tymeslot: true
      )

      mirror_for_link(link, source_uid: "source-uid-1", target_uid: "mirror-uid-1")

      insert_event(source, "Discovery call", ~T[14:00:00],
        uid: "booking-uid-1",
        created_by_tymeslot: true
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      refute html =~ "Busy"
      assert html =~ "Discovery call"
    end

    test "is hidden even when nothing else is", %{
      conn: conn,
      user: user,
      target: target,
      link: link
    } do
      # The filter sits behind a cheap exit that returns the event list untouched
      # when no account and no calendar is hidden. That is the ordinary state of
      # a grid, so a mirror set left out of that test would leak mirrors for
      # almost every organiser while the rejection below still read correctly.
      # This test therefore fixes the ordinary state explicitly: no hidden
      # account, no hidden calendar, one mirror.
      insert_event(target, "Mirrored block", ~T[09:00:00], uid: "mirror-uid-2")
      mirror_for_link(link, source_uid: "source-uid-2", target_uid: "mirror-uid-2")

      # Stated rather than assumed: if a later change made either of these
      # non-empty by default, the cheap exit would be skipped for another reason
      # and this test would stop guarding what it was written to guard.
      assert CalendarGrid.get_or_create_preferences(user.id).hidden_integration_ids == []
      assert Appearance.hidden_keys(Appearance.list_for_user(user.id)) == MapSet.new()

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      refute html =~ "Mirrored block"
    end

    test "hides only the mirror, not its neighbours on the same calendar", %{
      conn: conn,
      target: target,
      link: link
    } do
      insert_event(target, "Mirrored block", ~T[09:00:00], uid: "mirror-uid-3")
      insert_event(target, "Dentist", ~T[11:00:00], uid: "real-uid-3")
      mirror_for_link(link, source_uid: "source-uid-3", target_uid: "mirror-uid-3")

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      refute html =~ "Mirrored block"
      assert html =~ "Dentist"
    end

    test "a same-uid event on a different integration is untouched", %{
      conn: conn,
      source: source,
      target: target,
      link: link
    } do
      # The mirror set is keyed on {integration_id, uid}, not uid alone. Two
      # providers can hand back the same UID for unrelated events, and keying on
      # the UID by itself would take the innocent one off the grid too.
      insert_event(target, "Mirrored block", ~T[09:00:00], uid: "shared-uid")
      insert_event(source, "Real meeting", ~T[13:00:00], uid: "shared-uid")
      mirror_for_link(link, source_uid: "source-uid-4", target_uid: "shared-uid")

      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")

      refute html =~ "Mirrored block"
      assert html =~ "Real meeting"
    end
  end
end
