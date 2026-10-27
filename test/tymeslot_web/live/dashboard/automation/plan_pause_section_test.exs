defmodule TymeslotWeb.Dashboard.Automation.PlanPauseSectionTest do
  # The Automation section follows the `automations_allowed` assign. Core
  # standalone always allows automations, so the section renders as it always
  # has. When a deployment sets the assign false, an owner without
  # integrations sees only the configured placeholder (here Core's fallback),
  # and an owner with integrations sees the placeholder as a banner above the
  # tabs, every card paused.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :automation
  @moduletag :integration
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestFixtures

  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Onboarding.OnboardingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Webhooks.WebhookSchema

  @placeholder "This feature (Automation) is not available on your current plan."

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = OnboardingQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  defp lapse_plan do
    ConfigTestHelpers.setup_config(:tymeslot,
      feature_assigns: [
        automations_allowed: false,
        custom_questions_allowed: true,
        group_bookings_allowed: true,
        analytics_allowed: true,
        meeting_payments: false
      ]
    )
  end

  describe "with automations allowed (Core standalone)" do
    test "renders the tabs and cards with a working toggle, nothing paused",
         %{conn: conn, user: user} do
      webhook = insert(:webhook, user: user, name: "Bookings feed")

      {:ok, view, html} = live(conn, "/dashboard/automation")

      assert has_element?(view, "#automation-tabs")
      assert has_element?(view, "h3", "Bookings feed")
      refute html =~ @placeholder
      refute html =~ "Paused"
      refute has_element?(view, "#webhook-toggle-#{webhook.id}[disabled]")

      view |> element("#webhook-toggle-#{webhook.id}") |> render_click()

      refute Repo.get!(WebhookSchema, webhook.id).is_active
    end
  end

  describe "with automations not allowed" do
    setup do
      lapse_plan()
      :ok
    end

    test "an owner without integrations sees only the placeholder", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dashboard/automation")

      assert html =~ @placeholder
      refute has_element?(view, "#automation-tabs")
    end

    test "an owner with integrations sees the placeholder above paused cards",
         %{conn: conn, user: user} do
      webhook = insert(:webhook, user: user, name: "Bookings feed")

      {:ok, view, html} = live(conn, "/dashboard/automation")

      assert html =~ @placeholder
      assert has_element?(view, "#automation-tabs")
      assert has_element?(view, "h3", "Bookings feed")
      assert has_element?(view, "[data-part='notice']", "Upgrading resumes it.")
      assert has_element?(view, "#webhook-toggle-#{webhook.id}[disabled]")
      refute has_element?(view, "#webhook-toggle-#{webhook.id}[phx-click]")
    end
  end
end
