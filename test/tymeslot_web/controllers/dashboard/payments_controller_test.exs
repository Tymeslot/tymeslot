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

  test "POST /dashboard/payments/connect surfaces a try-later message when Stripe has restricted account creation",
       %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    expect(StripeAdapterMock, :create_account, fn _params, _opts ->
      {:error,
       %Stripe.Error{
         source: :stripe,
         code: :invalid_request_error,
         message:
           "We've temporarily restricted your ability to create this type of connected account due to suspicious activity."
       }}
    end)

    conn = post(conn, "/dashboard/payments/connect")
    assert redirected_to(conn) == "/dashboard/payments"
    assert Flash.get(conn.assigns.flash, :error) =~ "temporarily unavailable"
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

  test "POST /dashboard/payments/connect respects MEETING_PAYMENTS_DEFAULT_COUNTRY override",
       %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)
    conn = log_in_user(conn, user)

    previous = Application.get_env(:tymeslot, :meeting_payments_default_country)

    Application.put_env(:tymeslot, :meeting_payments_default_country, "de")

    on_exit(fn ->
      if previous do
        Application.put_env(:tymeslot, :meeting_payments_default_country, previous)
      else
        Application.delete_env(:tymeslot, :meeting_payments_default_country)
      end
    end)

    expect(StripeAdapterMock, :create_account, fn params, _opts ->
      assert params.country == "de"
      {:ok, %{id: "acct_DE", default_currency: "eur"}}
    end)

    expect(StripeAdapterMock, :create_account_link, fn _params ->
      {:ok, %{url: "https://connect.stripe.com/de"}}
    end)

    conn = post(conn, "/dashboard/payments/connect")
    assert redirected_to(conn, 302) == "https://connect.stripe.com/de"
  end
end
