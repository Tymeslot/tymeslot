defmodule TymeslotWeb.Dashboard.Automation.SlackCompositionTest do
  @moduledoc """
  Composition tests for the Slack integration LiveComponent.

  Verifies the wiring between AutomationSettingsComponent and the new Slack
  surface: tab visibility, primary/secondary CTAs in the empty state, the
  OAuth deep-link redirect target, and the feature gate that hides the
  section when automations are not allowed.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :slack
  @moduletag :automation
  @moduletag :live
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      slack_notifications_allowed: true,
      slack_oauth_available: true,
      slack_client_id: "test-client-id",
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "automation page composition" do
    test "exposes a Slack tab when slack_notifications_allowed is true",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = render(view)

      assert html =~ ~s(<span>Slack</span>)
    end

    test "renders the Slack empty state with both CTAs on the Slack tab",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button", "Slack") |> render_click()
      html = render(view)

      assert html =~ "No Slack Integrations"
      assert html =~ "Add to Slack"
      assert html =~ ~s(href="/api/slack/oauth/start")
      assert html =~ "Add via webhook URL"
    end

    test "clicking 'Add via webhook URL' opens the webhook URL form",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button", "Slack") |> render_click()
      view |> element("button", "Add via webhook URL") |> render_click()
      html = render(view)

      assert html =~ "Slack Webhook URL"
      assert html =~ "Incoming Webhook"
    end

    test "hides the Slack tab entirely when the feature flag is off",
         %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot, slack_notifications_allowed: false)

      {:ok, _view, html} = live(conn, "/dashboard/automation")

      refute html =~ ~s(<span>Slack</span>)
    end
  end

  describe "paywall enforcement" do
    test "hides Add to Slack and exposes only the webhook-URL fallback when OAuth is unavailable",
         %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot,
        slack_oauth_available: false,
        slack_client_id: nil
      )

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button", "Slack") |> render_click()
      html = render(view)

      refute html =~ "Add to Slack"
      assert html =~ "Add Slack via Webhook URL"
    end

    test "feature placeholder takes over when automations_allowed is false",
         %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot,
        feature_access_checker:
          TymeslotWeb.Dashboard.Automation.SlackCompositionTest.DeniedPlanChecker
      )

      {:ok, _view, html} = live(conn, "/dashboard/automation")

      # When the access checker denies automations, the dashboard renders its
      # feature placeholder instead of the Slack section. The Slack-specific
      # copy must not leak through.
      refute html =~ "No Slack Integrations"
    end
  end
end

defmodule TymeslotWeb.Dashboard.Automation.SlackCompositionTest.DeniedPlanChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: :ok | {:error, :insufficient_plan}
  def check_access(_user_id, :automations_allowed), do: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: :ok
end
