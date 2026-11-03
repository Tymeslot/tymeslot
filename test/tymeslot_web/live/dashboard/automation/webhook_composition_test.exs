defmodule TymeslotWeb.Dashboard.Automation.WebhookCompositionTest do
  @moduledoc """
  Composition tests for webhook CRUD in AutomationSettingsComponent.

  The existing `automation_integration_test.exs` already covers the
  happy-path create / edit / toggle / delete round-trip (line 33) and
  invalid-URL + empty-name form validation (line 121). This file fills
  the single remaining plan-required gap: the rate-limit seam between
  the LiveComponent, `&RateLimiter.check(:webhook_write, &1)/1`,
  and the `Webhooks.create_webhook/2` entry point.

  Dropped from the plan with rationale:

    * `handle_create` with invalid URL / empty name — already covered
      end-to-end in `automation_integration_test.exs:121` ("validation
      errors are shown"). Duplicating it here would be Credo-flavour
      coverage.
    * `handle_update` / `handle_regenerate_token` with nil form data
      — the plan itself dropped these as "defensive guards for states
      the UI can't emit".
    * `validate_field` with whitespace-only name — the handler deletes
      the error on empty/whitespace (line 48–50) and relies on
      changeset validation on submit; asserting the intermediate
      phx-blur state adds nothing.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :automation
  @moduletag :webhooks
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures

  alias Plug.HTML
  alias Plug.Test, as: PlugTest
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Onboarding.OnboardingQueries
  alias Tymeslot.RateLimiterTestHelpers
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Webhooks

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = OnboardingQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    conn = conn |> PlugTest.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  # The rendered page escapes apostrophes in the limiter's message.
  describe "handle_create — rate limit hit" do
    @tag :capture_log
    test "surfaces a flash and creates no webhook once the write limit is exhausted",
         %{conn: conn, user: user} do
      # Pre-exhaust the webhook-write bucket (30 per 30 minutes) so the
      # next create attempt trips the limiter before validation or
      # persistence can fire.
      Enum.each(1..30, fn _i ->
        :ok = RateLimiter.check(:webhook_write, user.id)
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")

      view
      |> element("button", "Create Your First Webhook")
      |> render_click()

      # Empty required fields reach the server, which answers in the form.
      assert has_element?(view, "#webhook-form[novalidate]")

      view
      |> form("#webhook-form", %{
        "webhook" => %{
          "name" => "Blocked Webhook",
          "url" => "https://example.com/webhook",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "limit of 30"
      refute html =~ "Webhook created successfully"
      assert Webhooks.list_webhooks(user.id) == []
    end
  end

  describe "handle_update — rate limit hit" do
    @tag :capture_log
    test "flashes the refusal and leaves the webhook unchanged", %{conn: conn, user: user} do
      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Original Name",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      message = RateLimiterTestHelpers.exhaust_limit!(:webhook_write, user.id)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button[title='Edit Webhook']") |> render_click()

      view
      |> form("#webhook-form", %{
        "webhook" => %{
          "name" => "Renamed Webhook",
          "url" => "https://example.com/webhook",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ HTML.html_escape(message)
      refute html =~ "Webhook updated successfully"
      assert {:ok, %{name: "Original Name"}} = Webhooks.get_webhook(webhook.id, user.id)
    end
  end

  describe "handle_regenerate_token — rate limit hit" do
    @tag :capture_log
    test "flashes the refusal and keeps the existing token", %{conn: conn, user: user} do
      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Token Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      message = RateLimiterTestHelpers.exhaust_limit!(:webhook_token_regen, user.id)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button[title='Edit Webhook']") |> render_click()
      view |> element("button[phx-click='show_regenerate_token_modal']") |> render_click()
      view |> element("#regenerate-token-modal .action-button--danger") |> render_click()

      html = render(view)
      assert html =~ HTML.html_escape(message)
      refute html =~ "Security token regenerated"
      assert [%{webhook_token: token}] = Webhooks.list_webhooks(user.id)
      assert token == webhook.webhook_token
    end
  end

  describe "handle_test_connection" do
    test "a webhook deleted since the page loaded is reported as not found",
         %{conn: conn, user: user} do
      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Gone Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      assert has_element?(view, "button[title='Test Connection']")

      {:ok, _deleted} = Webhooks.delete_webhook(user.id, webhook.id)

      view |> element("button[title='Test Connection']") |> render_click()

      html = render(view)
      assert html =~ "Webhook not found"
      refute html =~ "Unable to perform this action"
    end

    @tag :capture_log
    test "flashes the refusal instead of testing once the test limit is exhausted",
         %{conn: conn, user: user} do
      {:ok, _webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Limited Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      message = RateLimiterTestHelpers.exhaust_limit!(:webhook_test, user.id)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button[title='Test Connection']") |> render_click()

      html = render(view)
      assert html =~ HTML.html_escape(message)
      refute html =~ "Webhook test successful"
    end
  end
end
