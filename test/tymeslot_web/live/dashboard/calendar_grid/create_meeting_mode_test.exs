defmodule TymeslotWeb.Dashboard.CalendarGrid.CreateMeetingModeTest do
  @moduledoc """
  Covers the Quick add modal's meeting mode: an ad-hoc Tymeslot meeting
  created straight from the grid — mode selection, validation, and the
  async result plumbing.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  defp open_create_form(lv) do
    lv
    |> element("#calendar-grid")
    |> render_hook("show_create_form", %{})
  end

  describe "without any calendar integration" do
    test "quick add opens directly in meeting mode", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html = open_create_form(lv)

      assert html =~ ~s(id="create-event-modal")
      assert html =~ "New Meeting"
      assert html =~ ~s(id="create-meeting-guest-name")
      assert html =~ ~s(id="create-meeting-guest-email")
      # No mode toggle: an event has nowhere to be written.
      refute html =~ ~s(data-testid="create-mode-meeting")
    end

    test "saving without guest details flashes a validation error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_create_form(lv)

      lv |> element("#calendar-grid") |> render_hook("save_event", %{})
      html = render(lv)

      assert html =~ "Guest name is required"
      # Modal stays open for correction.
      assert html =~ ~s(id="create-event-modal")
    end

    test "saving with a guest but invalid email flashes an email error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_create_guest_name", %{"value" => "Ada Lovelace"})

      lv
      |> element("#calendar-grid")
      |> render_hook("update_create_guest_email", %{"value" => "not-an-email"})

      lv |> element("#calendar-grid") |> render_hook("save_event", %{})

      assert render(lv) =~ "A valid guest email is required"
    end

    test "a valid meeting save enters the creating state", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_create_form(lv)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_create_guest_name", %{"value" => "Ada Lovelace"})

      lv
      |> element("#calendar-grid")
      |> render_hook("update_create_guest_email", %{"value" => "ada@example.com"})

      html = lv |> element("#calendar-grid") |> render_hook("save_event", %{})

      # The save dispatched to the async ad-hoc path and the button shows its
      # loading state while the meeting is created.
      assert html =~ "Creating..."
    end
  end

  describe "with a calendar integration" do
    test "the modal offers an event/meeting toggle defaulting to event", %{
      conn: conn,
      user: user
    } do
      insert(:calendar_integration, user: user, is_active: true)

      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html = open_create_form(lv)

      assert html =~ "New Event"
      assert html =~ ~s(data-testid="create-mode-meeting")
      refute html =~ ~s(id="create-meeting-guest-name")

      html =
        lv
        |> element(~s{[data-testid="create-mode-meeting"]})
        |> render_click()

      assert html =~ "New Meeting"
      assert html =~ ~s(id="create-meeting-guest-name")
    end
  end

  describe "result plumbing" do
    test "a successful result closes the modal and flashes", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_create_form(lv)

      send(lv.pid, {:create_ad_hoc_meeting_result, {:ok, %{meeting_id: "x"}}})

      # The handler `send_update`s the grid component; that update is queued
      # behind the first render request, so render twice to observe it.
      _first = render(lv)
      html = render(lv)

      refute html =~ ~s(id="create-event-modal")
      assert html =~ "Meeting created and invitation sent"
    end

    test "a failed result keeps the modal open and flashes the reason", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_create_form(lv)

      send(lv.pid, {:create_ad_hoc_meeting_result, {:error, "Attendee email is required"}})
      html = render(lv)

      assert html =~ ~s(id="create-event-modal")
      assert html =~ "Attendee email is required"
    end
  end
end
