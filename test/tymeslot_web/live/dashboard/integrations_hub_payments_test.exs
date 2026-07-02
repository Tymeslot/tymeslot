defmodule TymeslotWeb.Dashboard.IntegrationsHubPaymentsTest do
  # `async: false`: these tests toggle the global `:meeting_payments_enabled`
  # and `:feature_access_checker` application env, which is shared state.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :payments

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  setup do
    # Force the Core default checker so the runtime feature flag is honoured
    # regardless of whether the SaaS overlay is configured.
    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    on_exit(fn ->
      if previous_checker do
        Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
      else
        Application.delete_env(:tymeslot, :feature_access_checker)
      end
    end)

    :ok
  end

  defp set_payments_enabled(enabled?) do
    previous = Application.get_env(:tymeslot, :meeting_payments_enabled)
    Application.put_env(:tymeslot, :meeting_payments_enabled, enabled?)
    on_exit(fn -> Application.put_env(:tymeslot, :meeting_payments_enabled, previous) end)
    :ok
  end

  describe "when payments access is denied" do
    setup do: set_payments_enabled(false)

    test "does not render the Payments tab link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      refute html =~ ~s(href="/dashboard/integrations?tab=payments")
    end

    test "falls back to calendars when ?tab=payments is requested", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=payments")

      assert html =~ ~s(data-tab-panel="calendars")
      refute html =~ ~s(data-tab-panel="payments")
    end
  end

  describe "when payments access is allowed" do
    setup do: set_payments_enabled(true)

    test "renders the Payments tab link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations")

      assert html =~ ~s(href="/dashboard/integrations?tab=payments")
    end

    test "shows the Connect Stripe CTA when no connect account exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=payments")

      assert html =~ ~s(data-tab-panel="payments")
      assert html =~ "Connect Stripe"
    end

    test "shows the connected operations UI for a ready connect account",
         %{conn: conn, user: user} do
      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_hub_ready",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=payments")

      assert html =~ "Connected and ready"
      assert html =~ "Recent payments"
    end
  end
end
