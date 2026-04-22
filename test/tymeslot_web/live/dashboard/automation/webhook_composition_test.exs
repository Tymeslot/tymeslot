defmodule TymeslotWeb.Dashboard.Automation.WebhookCompositionTest do
  @moduledoc """
  Composition tests for webhook CRUD in AutomationSettingsComponent.

  The existing `automation_integration_test.exs` already covers the
  happy-path create / edit / toggle / delete round-trip (line 33) and
  invalid-URL + empty-name form validation (line 121). This file fills
  the single remaining plan-required gap: the rate-limit seam between
  the LiveComponent, `RateLimiter.check_webhook_write_rate_limit/1`,
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

  alias Plug.Test, as: PlugTest
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Webhooks

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    conn = conn |> PlugTest.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "handle_create — rate limit hit" do
    @tag :capture_log
    test "surfaces a flash and creates no webhook once the write limit is exhausted",
         %{conn: conn, user: user} do
      # Pre-exhaust the webhook-write bucket (30 per 30 minutes) so the
      # next create attempt trips the limiter before validation or
      # persistence can fire.
      Enum.each(1..30, fn _i ->
        :ok = RateLimiter.check_webhook_write_rate_limit(user.id)
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")

      view
      |> element("button", "Create Your First Webhook")
      |> render_click()

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
end
