defmodule TymeslotWeb.Dashboard.MeetingTypeFormSlotIntervalTest do
  @moduledoc """
  Round-trips the booking-slot-interval select through the real edit form.

  The column is only reachable by a product user through this select, so
  unit coverage of the layers beneath it (validation, the schema, the form
  mapper) proves nothing about whether a host can actually change it. This
  drives the select itself: it renders, a choice persists, re-opening the
  form reflects it, and picking "Same as meeting length" again clears the
  column back to NULL rather than to an explicit copy of the duration —
  the invariant three downstream call sites branch on.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  setup :setup_dashboard_user

  defp open_edit_form(view, meeting_type) do
    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()
  end

  defp close_edit_form(view) do
    view |> element("button", "Done") |> render_click()
  end

  defp selected_slot_interval_option(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s|select[name="meeting_type[slot_interval]"] option[selected]|)
  end

  defp selected_slot_interval_value(html) do
    case Floki.attribute(selected_slot_interval_option(html), "value") do
      [value] -> value
      [] -> nil
    end
  end

  describe "the booking slot interval select" do
    test "renders with 'Same as meeting length' available and selected when no interval is set",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 45, slot_interval_minutes: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      html = open_edit_form(view, meeting_type)

      assert has_element?(view, ~s|select[name="meeting_type[slot_interval]"]|)

      document = Floki.parse_document!(html)

      options = Floki.find(document, ~s|select[name="meeting_type[slot_interval]"] option|)

      assert Enum.any?(options, &(Floki.text(&1) =~ "Same as meeting length"))

      assert selected_slot_interval_value(html) == ""
    end

    test "choosing a value persists it, and re-opening the form shows it selected",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      view
      |> element(~s|select[name="meeting_type[slot_interval]"]|)
      |> render_change(%{"meeting_type" => %{"slot_interval" => "20"}})

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).slot_interval_minutes == 20

      close_edit_form(view)
      html = open_edit_form(view, meeting_type)

      assert selected_slot_interval_value(html) == "20"
    end

    test "choosing 'Same as meeting length' again clears the column back to NULL",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: 20)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      view
      |> element(~s|select[name="meeting_type[slot_interval]"]|)
      |> render_change(%{"meeting_type" => %{"slot_interval" => ""}})

      updated = MeetingTypes.get_meeting_type(meeting_type.id, user.id)

      # NULL, never an explicit copy of the duration — a stored 60 here would
      # be indistinguishable from a deliberate 60-minute interval on a form
      # that renders identically.
      assert updated.slot_interval_minutes == nil
      refute updated.slot_interval_minutes == updated.duration_minutes
    end

    test "a value outside the common table still renders as its own selected option",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: 7)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      html = open_edit_form(view, meeting_type)

      assert selected_slot_interval_value(html) == "7"

      # Saving an unrelated field must not silently erase the out-of-table
      # value — this is the bug wave 1 fixed.
      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "Renamed"}})

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).slot_interval_minutes == 7
    end
  end
end
