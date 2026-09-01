defmodule TymeslotWeb.Dashboard.MeetingTypeFormSlotIntervalTest do
  @moduledoc """
  Round-trips the booking-slot-interval control through the real edit form.

  The column is only reachable by a product user through this control, so
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
  alias Tymeslot.Validation.Constraints

  setup :setup_dashboard_user

  defp open_edit_form(view, meeting_type) do
    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()
  end

  defp close_edit_form(view) do
    view |> element("button", "Done") |> render_click()
  end

  defp custom_input_selector, do: ~s|input[type="number"][name="meeting_type[slot_interval]"]|

  defp custom_input_value(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(custom_input_selector())
    |> Floki.attribute("value")
    |> List.first()
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

    test "a value outside the common table opens the custom input holding it",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: 7)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      html = open_edit_form(view, meeting_type)

      # The dropdown cannot show 7 as a choice, so it reports the mode and the
      # number input carries the value. Rendering it as a selected option
      # instead would leave it visible but not editable.
      assert selected_slot_interval_value(html) == "custom"
      assert custom_input_value(html) == "7"

      # Saving an unrelated field must not silently erase the out-of-table
      # value — this is the bug wave 1 fixed.
      view
      |> element(~s|input[name="meeting_type[name]"]|)
      |> render_change(%{"meeting_type" => %{"name" => "Renamed"}})

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).slot_interval_minutes == 7
    end
  end

  describe "the custom interval input" do
    test "is absent until Custom is chosen, and appears when it is",
         %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: 15)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      refute has_element?(view, custom_input_selector())

      view
      |> element(~s|select[name="meeting_type[slot_interval]"]|)
      |> render_change(%{"meeting_type" => %{"slot_interval" => "custom"}})

      assert has_element?(view, custom_input_selector())

      # "Custom" names a mode, not a duration: it must not be stored, and it
      # must not wipe the interval already set.
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).slot_interval_minutes == 15
    end

    test "saves a value the dropdown does not offer", %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      view
      |> element(~s|select[name="meeting_type[slot_interval]"]|)
      |> render_change(%{"meeting_type" => %{"slot_interval" => "custom"}})

      view
      |> element(custom_input_selector())
      |> render_change(%{"meeting_type" => %{"slot_interval" => "7"}})

      # 7 is absent from the dropdown, so before the custom input existed this
      # value could only be written straight to the database.
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).slot_interval_minutes == 7
    end

    test "rejects a value outside the validated range", %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      view
      |> element(~s|select[name="meeting_type[slot_interval]"]|)
      |> render_change(%{"meeting_type" => %{"slot_interval" => "custom"}})

      html =
        view
        |> element(custom_input_selector())
        |> render_change(%{"meeting_type" => %{"slot_interval" => "3"}})

      assert html =~ "at least #{Constraints.slot_interval_minutes_range().first}"
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).slot_interval_minutes == nil
    end

    test "picking a listed value again closes it", %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 60, slot_interval_minutes: 7)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)
      assert has_element?(view, custom_input_selector())

      view
      |> element(~s|select[name="meeting_type[slot_interval]"]|)
      |> render_change(%{"meeting_type" => %{"slot_interval" => "15"}})

      refute has_element?(view, custom_input_selector())
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).slot_interval_minutes == 15
    end
  end

  describe "the hint beneath the control" do
    test "spells out the times the chosen interval produces", %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 30, slot_interval_minutes: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      open_edit_form(view, meeting_type)

      html =
        view
        |> element(~s|select[name="meeting_type[slot_interval]"]|)
        |> render_change(%{"meeting_type" => %{"slot_interval" => "5"}})

      # The point of the hint: five minutes and sixty minutes are the same
      # sentence until the times are shown.
      assert html =~ "every 5 minutes"
      assert html =~ "09:00 AM, 09:05 AM, 09:10 AM"
    end

    test "steps by the meeting length while no interval is set", %{conn: conn, user: user} do
      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 45, slot_interval_minutes: nil)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      html = open_edit_form(view, meeting_type)

      assert html =~ "every 45 minutes"
      assert html =~ "09:00 AM, 09:45 AM, 10:30 AM"
    end
  end
end
