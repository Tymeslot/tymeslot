defmodule TymeslotWeb.Dashboard.Automation.TabStripTest do
  @moduledoc """
  The automation page's channel tabs: switching between them through the
  shared tab strip, the panel's ARIA wiring, and how channels switched off on
  this server appear.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :automation
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures

  alias Plug.Test, as: PlugTest
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Onboarding.OnboardingQueries

  defp open_page(conn, config) do
    ConfigTestHelpers.setup_config(
      :tymeslot,
      [
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        dashboard_additional_hooks: [],
        feature_placeholder_components: %{}
      ] ++ config
    )

    user = create_user_fixture()
    {:ok, user} = OnboardingQueries.mark_onboarding_complete(user)

    conn =
      conn
      |> PlugTest.init_test_session(%{})
      |> fetch_session()
      |> log_in_user(user)

    {:ok, view, _html} = live(conn, "/dashboard/automation")
    view
  end

  test "clicking a channel tab selects it and shows its panel", %{conn: conn} do
    view =
      open_page(conn,
        telegram_notifications_allowed: true,
        telegram_shared_bot: false,
        slack_notifications_allowed: false
      )

    assert has_element?(view, "#automation-tabs-tab-webhooks[aria-selected='true']")

    assert has_element?(
             view,
             "#automation-tabs-panel-webhooks[role='tabpanel'][aria-labelledby='automation-tabs-tab-webhooks']"
           )

    view |> element("#automation-tabs-tab-telegram") |> render_click()

    assert has_element?(view, "#automation-tabs-tab-telegram[aria-selected='true']")
    assert has_element?(view, "#automation-tabs-tab-webhooks[aria-selected='false']")

    assert has_element?(
             view,
             "#automation-tabs-tab-telegram[aria-controls='automation-tabs-panel-telegram']"
           )

    assert has_element?(
             view,
             "#automation-tabs-panel-telegram[aria-labelledby='automation-tabs-tab-telegram']"
           )

    refute has_element?(view, "#automation-tabs-panel-webhooks")
    assert has_element?(view, "#automation-tabs-panel-telegram", "Add Telegram Account")
  end

  test "a channel switched off is shown disabled, and Slack is left out", %{conn: conn} do
    view =
      open_page(conn,
        telegram_notifications_allowed: false,
        slack_notifications_allowed: false
      )

    assert has_element?(view, "#automation-tabs-tab-telegram[disabled]", "Disabled")
    refute has_element?(view, "#automation-tabs-tab-webhooks[disabled]")
    refute has_element?(view, "#automation-tabs-tab-slack")
  end
end
