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

  defp open_new_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")
    view |> element("button", "Add Meeting Type") |> render_click()
    # The default reminder's hidden inputs break Plug.Conn.Query re-encoding on
    # submit; the other form tests remove it the same way.
    view |> element("button[aria-label='Remove reminder']") |> render_click()
    view
  end

  defp gated_form(conn) do
    view = open_new_form(conn)
    view |> element("[data-testid='requires-approval-toggle']") |> render_click()
    view
  end

  defp submit(view, attrs) do
    view
    |> form("form[phx-submit='save_meeting_type']", %{"meeting_type" => attrs})
    |> render_submit()
  end

  defp saved_type(user, name) do
    Enum.find(MeetingTypes.get_all_meeting_types(user.id), &(&1.name == name))
  end

  describe "the toggle" do
    test "is offered on the booking rules tab", %{conn: conn} do
      html = render(open_new_form(conn))

      assert html =~ "Confirm each booking myself"
    end

    test "hides the window until approval is actually on", %{conn: conn} do
      view = open_new_form(conn)

      refute render(view) =~ "data-testid=\"approval-window-hours\""

      view |> element("[data-testid='requires-approval-toggle']") |> render_click()

      assert render(view) =~ "data-testid=\"approval-window-hours\""
    end
  end

  describe "saving" do
    test "a meeting type saved with the toggle on actually gates its bookings",
         %{conn: conn, user: user} do
      submit(gated_form(conn), %{"name" => "Vetted intro", "duration" => "30"})

      saved = saved_type(user, "Vetted intro")

      assert saved.requires_approval
      # The switch is only real if the domain agrees with it.
      assert Approval.required?(saved)
    end

    test "leaving the window blank means the application default, not a frozen copy",
         %{conn: conn, user: user} do
      submit(gated_form(conn), %{"name" => "Default window", "duration" => "30"})

      saved = saved_type(user, "Default window")

      assert is_nil(saved.approval_window_hours)
      assert Approval.window_hours(saved) == Constraints.default_approval_window_hours()
    end

    test "a window the host types is stored and used", %{conn: conn, user: user} do
      view = gated_form(conn)

      view
      |> element("[data-testid='approval-window-hours']")
      |> render_change(%{"meeting_type" => %{"approval_window_hours" => "6"}})

      submit(view, %{"name" => "Six hours", "duration" => "30"})

      saved = saved_type(user, "Six hours")

      assert saved.approval_window_hours == 6
      assert Approval.window_hours(saved) == 6
    end

    test "a window outside the allowed range is refused", %{conn: conn, user: user} do
      view = gated_form(conn)
      too_long = Constraints.approval_window_hours_range().last + 1

      view
      |> element("[data-testid='approval-window-hours']")
      |> render_change(%{"meeting_type" => %{"approval_window_hours" => to_string(too_long)}})

      submit(view, %{"name" => "Too long", "duration" => "30"})

      assert is_nil(saved_type(user, "Too long"))
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
