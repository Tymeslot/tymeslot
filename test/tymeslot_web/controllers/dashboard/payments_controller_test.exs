defmodule TymeslotWeb.Dashboard.PaymentsControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :database
  @moduletag :payments

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Flash

  setup :verify_on_exit!

  setup do
    previous_payments = Application.get_env(:tymeslot, :meeting_payments_enabled)
    Application.put_env(:tymeslot, :meeting_payments_enabled, true)

    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    on_exit(fn ->
      Application.put_env(:tymeslot, :meeting_payments_enabled, previous_payments)

      if previous_checker do
        Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
      else
        Application.delete_env(:tymeslot, :feature_access_checker)
      end
    end)

    :ok
  end

  test "POST /dashboard/payments/connect redirects to Stripe's authorise page", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    conn = post(conn, "/dashboard/payments/connect")

    assert %URI{host: "connect.stripe.com", path: "/oauth/authorize"} =
             URI.parse(redirected_to(conn, 302))
  end

  test "POST /dashboard/payments/connect flashes and redirects on failure", %{conn: conn} do
    with_config(:tymeslot, stripe_connect_client_id: nil)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    conn = post(conn, "/dashboard/payments/connect")
    assert redirected_to(conn) == "/dashboard/payments"
    assert Flash.get(conn.assigns.flash, :error) =~ "Could not start"
  end

  test "POST /dashboard/payments/connect is rejected when the feature is disabled", %{conn: conn} do
    # Forged request: the UI hides the button, but a direct POST must not be
    # able to start onboarding when the operator toggle is off. No Stripe call
    # is expected — Mox verify_on_exit! enforces this.
    Application.put_env(:tymeslot, :meeting_payments_enabled, false)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    conn = post(conn, "/dashboard/payments/connect")

    assert redirected_to(conn) == "/dashboard/payments"
    assert Flash.get(conn.assigns.flash, :error) =~ "not enabled"
  end
end
