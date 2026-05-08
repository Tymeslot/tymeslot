defmodule TymeslotWeb.Dashboard.PaymentsControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :database
  @moduletag :payments

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  setup :verify_on_exit!

  setup do
    Application.put_env(:tymeslot, :meeting_payments_enabled, true)

    previous_checker = Application.get_env(:tymeslot, :feature_access_checker)

    Application.put_env(
      :tymeslot,
      :feature_access_checker,
      Tymeslot.Features.DefaultAccessChecker
    )

    on_exit(fn ->
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)

      if previous_checker do
        Application.put_env(:tymeslot, :feature_access_checker, previous_checker)
      else
        Application.delete_env(:tymeslot, :feature_access_checker)
      end
    end)

    :ok
  end

  test "POST /dashboard/payments/connect redirects to Stripe AccountLink", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    expect(StripeAdapterMock, :create_account, fn _params, _opts ->
      {:ok, %{id: "acct_TEST", default_currency: "eur"}}
    end)

    expect(StripeAdapterMock, :create_account_link, fn _params ->
      {:ok, %{url: "https://connect.stripe.com/onboard"}}
    end)

    conn = post(conn, "/dashboard/payments/connect")
    assert redirected_to(conn, 302) == "https://connect.stripe.com/onboard"
  end

  test "POST /dashboard/payments/connect flashes and redirects on failure", %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    expect(StripeAdapterMock, :create_account, fn _params, _opts ->
      {:error, %{message: "boom"}}
    end)

    conn = post(conn, "/dashboard/payments/connect")
    assert redirected_to(conn) == "/dashboard/payments"
    assert Flash.get(conn.assigns.flash, :error) =~ "Could not start"
  end
end
