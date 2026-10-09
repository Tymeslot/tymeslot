defmodule TymeslotWeb.Dashboard.CalendarGrid.CreateMeetingRemindersTest do
  @moduledoc """
  The reminders a host can set on a quick-added meeting, through the same
  picker a meeting type offers. Driven through the controls themselves and the
  real creation task, so what is asserted is what a save actually produced.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(), locale: "en")
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp open_form(lv) do
    lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})
  end

  defp hook(lv, event, params) do
    lv |> element("#calendar-grid") |> render_hook(event, params)
  end

  defp fill_guest(lv) do
    hook(lv, "update_create_guest_name", %{"value" => "Ada Lovelace"})
    hook(lv, "update_create_guest_email", %{"value" => "ada@example.com"})
  end

  # Creation runs in a supervised task, so the row appears a moment after the
  # event returns.
  defp created_meeting(tries \\ 50) do
    case Repo.one(MeetingSchema) do
      nil when tries > 0 ->
        Process.sleep(20)
        created_meeting(tries - 1)

      meeting ->
        meeting
    end
  end

  # The picker's own controls, driven the way the host does: the preset
  # buttons post through `JS.push`, the custom row through the form it sits in.
  defp click_preset(lv, testid) do
    lv |> element(~s{[data-testid="#{testid}"]}) |> render_click()
  end

  defp add_custom(lv, value, unit) do
    lv |> element(~s{[data-testid="reminder-custom-toggle"]}) |> render_click()

    lv
    |> form("#create-meeting-reminders-form", %{"reminder" => %{"value" => value, "unit" => unit}})
    |> render_submit()
  end

  describe "reminders" do
    test "the picker is offered in meeting mode only", %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, is_active: true)
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html = open_form(lv)

      # Event mode carries provider alarms instead, which are a different
      # thing: they ring on the organiser's own devices and email nobody.
      refute html =~ "reminder emails for this meeting."
      assert html =~ "Reminders are synced to your calendar"

      html = lv |> element(~s{[data-testid="create-mode-meeting"]}) |> render_click()

      assert html =~ "reminder emails for this meeting."
      refute html =~ "Reminders are synced to your calendar"
    end

    test "a preset lead time is added by its button", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)

      html = click_preset(lv, "reminder-preset-30-minutes")

      assert html =~ "30 minutes before"
      # The button for a lead time already held is not offered again.
      refute html =~ ~s(data-testid="reminder-preset-30-minutes")
    end

    test "a custom lead time is added through the custom row", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)

      html = add_custom(lv, "2", "hours")

      assert html =~ "2 hours before"
    end

    test "the custom row is validated, and says why", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)

      html = add_custom(lv, "0", "minutes")

      assert html =~ "Reminder value must be a positive number"
    end

    test "no more than the policy allows can be added", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)

      click_preset(lv, "reminder-preset-30-minutes")
      click_preset(lv, "reminder-preset-60-minutes")
      html = add_custom(lv, "1", "days")

      assert html =~ "1 day before"
      # Every way in is closed once the cap is reached, rather than answering
      # a fourth attempt with an error.
      refute html =~ ~s(data-testid="reminder-preset-30-minutes")
      refute html =~ ~s(data-testid="reminder-preset-60-minutes")
      assert html =~ ~s(data-testid="reminder-custom-toggle" disabled)
    end

    test "what the host picked is what the meeting reminds with", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)

      click_preset(lv, "reminder-preset-60-minutes")
      hook(lv, "save_event", %{})

      assert created_meeting().reminders == [%{"value" => 60, "unit" => "minutes"}]
    end

    test "picking none means none, not the legacy default", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)
      fill_guest(lv)
      hook(lv, "save_event", %{})

      assert created_meeting().reminders == []
    end

    test "a reminder can be taken off again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      open_form(lv)

      click_preset(lv, "reminder-preset-30-minutes")

      html =
        lv
        |> element(~s{[data-testid="reminder-remove"]})
        |> render_click()

      assert html =~ "No reminders configured."
    end
  end
end
