defmodule TymeslotWeb.Dashboard.MeetingTypeFormApprovalTest do
  @moduledoc """
  The switch that makes the approval gate reachable.

  Everything else in this feature is inert until a host turns this on, so the
  test that matters is the round trip: toggling it and saving must produce a
  meeting type whose bookings are actually held, not just a checkbox that
  renders ticked.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :bookings
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Validation.Constraints

  setup :setup_dashboard_user

  setup %{user: user} do
    %{meeting_type: insert(:meeting_type, user: user, name: "Vetted intro")}
  end

  # Opens the editor on an existing meeting type: approval sits on the Booking
  # Rules tab, which only exists once the type does, and every change there
  # auto-saves.
  defp open_form(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end

  defp gated_form(conn, meeting_type) do
    view = open_form(conn, meeting_type)
    view |> element("[data-testid='requires-approval-toggle']") |> render_click()
    view
  end

  defp type_window(view, hours) do
    view
    |> element("[data-testid='approval-window-hours']")
    |> render_change(%{"meeting_type" => %{"approval_window_hours" => hours}})
  end

  defp saved(meeting_type),
    do: MeetingTypes.get_meeting_type(meeting_type.id, meeting_type.user_id)

  describe "the toggle" do
    test "is offered on the booking rules tab", %{conn: conn, meeting_type: meeting_type} do
      view = open_form(conn, meeting_type)

      assert has_element?(
               view,
               "#meeting-type-form-tabs-panel-booking [data-testid='requires-approval-toggle']"
             )

      assert render(view) =~ "Confirm each booking myself"
    end

    test "hides the window until approval is actually on", %{
      conn: conn,
      meeting_type: meeting_type
    } do
      view = open_form(conn, meeting_type)

      refute render(view) =~ "data-testid=\"approval-window-hours\""

      view |> element("[data-testid='requires-approval-toggle']") |> render_click()

      assert render(view) =~ "data-testid=\"approval-window-hours\""
    end
  end

  describe "saving" do
    test "turning the toggle on actually gates the meeting type's bookings",
         %{conn: conn, meeting_type: meeting_type} do
      gated_form(conn, meeting_type)

      saved = saved(meeting_type)

      assert saved.requires_approval
      # The switch is only real if the domain agrees with it.
      assert Approval.required?(saved)
    end

    test "leaving the window blank means the application default, not a frozen copy",
         %{conn: conn, meeting_type: meeting_type} do
      gated_form(conn, meeting_type)

      saved = saved(meeting_type)

      assert is_nil(saved.approval_window_hours)
      assert Approval.window_hours(saved) == Constraints.default_approval_window_hours()
    end

    test "a window the host types is stored and used", %{conn: conn, meeting_type: meeting_type} do
      conn |> gated_form(meeting_type) |> type_window("6")

      saved = saved(meeting_type)

      assert saved.approval_window_hours == 6
      assert Approval.window_hours(saved) == 6
    end

    test "a window outside the allowed range is refused", %{
      conn: conn,
      meeting_type: meeting_type
    } do
      too_long = Constraints.approval_window_hours_range().last + 1

      conn |> gated_form(meeting_type) |> type_window(to_string(too_long))

      assert is_nil(saved(meeting_type).approval_window_hours)
    end
  end

  describe "typing an invalid window" do
    test "a non-numeric value surfaces an error rather than becoming the default silently", %{
      conn: conn,
      meeting_type: meeting_type
    } do
      html = conn |> gated_form(meeting_type) |> type_window("abc")

      assert html =~ "Enter a whole number of hours"
    end

    test "zero and a negative number are refused the same way", %{
      conn: conn,
      meeting_type: meeting_type
    } do
      view = gated_form(conn, meeting_type)

      for bad <- ["0", "-5"] do
        assert type_window(view, bad) =~ "Enter a whole number of hours"
      end
    end

    test "does not overwrite a previously saved good value with a parse failure", %{
      conn: conn,
      meeting_type: meeting_type
    } do
      view = gated_form(conn, meeting_type)

      type_window(view, "6")
      type_window(view, "abc")

      assert saved(meeting_type).approval_window_hours == 6
    end
  end

  describe "editing an existing meeting type" do
    test "shows the saved window rather than the default", %{conn: conn, user: user} do
      type =
        insert(:meeting_type,
          user: user,
          user_id: user.id,
          name: "Already gated",
          requires_approval: true,
          approval_window_hours: 8
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("button[phx-click='edit_type'][phx-value-id='#{type.id}']")
      |> render_click()

      assert render(view) =~ "Confirm each booking myself"

      # The host's own window, not the application default, which is 24.
      window = view |> element("[data-testid='approval-window-hours']") |> render()
      assert window =~ ~s(value="8")
    end
  end
end
