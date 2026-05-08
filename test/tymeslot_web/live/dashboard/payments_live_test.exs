defmodule TymeslotWeb.Dashboard.PaymentsLiveTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :database
  @moduletag :payments

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  defp create_onboarded_user do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    user
  end

  setup do
    # Force the Core default checker so the runtime feature flag is
    # honoured regardless of whether the SaaS overlay is configured.
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

  describe "/dashboard/payments — when feature disabled" do
    setup do
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)
      :ok
    end

    test "redirects to dashboard root with flash", %{conn: conn} do
      user = create_onboarded_user()
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/dashboard", flash: flash}}} =
               live(conn, "/dashboard/payments")

      assert flash["error"] =~ "not available"
    end
  end

  describe "/dashboard/payments — when feature enabled, no Stripe" do
    setup do
      Application.put_env(:tymeslot, :meeting_payments_enabled, true)
      on_exit(fn -> Application.put_env(:tymeslot, :meeting_payments_enabled, false) end)
      :ok
    end

    test "renders Connect Stripe CTA", %{conn: conn} do
      user = create_onboarded_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/dashboard/payments")
      assert html =~ "Connect Stripe"
    end
  end
end
