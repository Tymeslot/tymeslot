defmodule TymeslotWeb.Dashboard.PaymentsLiveTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :database
  @moduletag :payments

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingTypes.MeetingTypeQueries

  setup :verify_on_exit!
  setup :set_mox_from_context

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

  describe "/dashboard/payments — with active Stripe account" do
    setup do
      Application.put_env(:tymeslot, :meeting_payments_enabled, true)
      on_exit(fn -> Application.put_env(:tymeslot, :meeting_payments_enabled, false) end)
      :ok
    end

    test "shows green status when charges_enabled and payouts_enabled", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_green",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/dashboard/payments")

      assert html =~ "Connected and ready"
      assert html =~ "Recent payments"
    end

    test "shows amber when details submitted but charges disabled", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_amber",
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: true
      )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/dashboard/payments")

      assert html =~ "Pending Stripe review"
    end

    test "shows red when disabled_reason is set", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_red",
        disabled_reason: "rejected.fraud"
      )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/dashboard/payments")

      assert html =~ "Restricted"
      assert html =~ "rejected.fraud"
    end

    test "disconnect button soft-deletes the connect_account", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_disco",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/dashboard/payments")

      view |> element("button[phx-click=disconnect]") |> render_click()

      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "change_currency updates the account currency and resets paid event types", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_currency",
        default_currency: "eur",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      paid_mt =
        insert(:meeting_type, user: user, payment_required: true, price_cents: 5000)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/dashboard/payments")

      view
      |> form("form[phx-change=change_currency]", %{"currency" => "gbp"})
      |> render_change()

      account = ConnectAccountQueries.live_for_user(user.id)
      assert account.default_currency == "gbp"

      reloaded = MeetingTypeQueries.get_meeting_type!(paid_mt.id)
      assert reloaded.payment_required == false
      assert reloaded.price_cents == nil
    end
  end

  describe "/dashboard/payments — refund flow" do
    setup do
      Application.put_env(:tymeslot, :meeting_payments_enabled, true)
      on_exit(fn -> Application.put_env(:tymeslot, :meeting_payments_enabled, false) end)
      :ok
    end

    defp paid_payment_for(user, attrs \\ %{}) do
      defaults = %{
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_REFUND",
        stripe_charge_id: "ch_REFUND_#{System.unique_integer([:positive])}",
        amount_cents: 5000,
        application_fee_cents: 25,
        currency: "eur",
        status: "paid",
        paid_at: DateTime.utc_now(:second),
        refunded_amount_cents: 0,
        attendee_email: "alice@example.com",
        attendee_name: "Alice",
        meeting_type_name: "Consult",
        booking_theme_id: "1"
      }

      insert(:booking_payment, Map.merge(defaults, Map.new(attrs)))
    end

    test "renders refund button for refundable payments only", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_REFUND",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      _refundable = paid_payment_for(user)

      _expired =
        paid_payment_for(user, %{
          paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day)
        })

      _pending = paid_payment_for(user, %{status: "pending", paid_at: nil})

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/dashboard/payments")

      buttons = view |> element("table") |> render() |> String.split("Refund") |> length()
      # 1 refund button → 2 segments after split (header text doesn't include "Refund")
      assert buttons == 2
    end

    test "submitting a full refund issues the refund and updates the row", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_REFUND",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      payment = paid_payment_for(user)

      expect(StripeAdapterMock, :create_refund, fn params, opts ->
        assert params.amount == 5000
        assert opts[:idempotency_key] == "refund:#{payment.id}:5000:5000"
        {:ok, %{id: "re_full"}}
      end)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/dashboard/payments")

      view
      |> element("button[phx-click=open_refund_modal]", "Refund")
      |> render_click()

      view
      |> form("#refund-form", %{"refund_type" => "full"})
      |> render_submit()

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000
    end

    test "submitting a partial refund updates the row to partially_refunded", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_REFUND",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      payment = paid_payment_for(user)

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.amount == 1500
        {:ok, %{id: "re_partial"}}
      end)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, "/dashboard/payments")

      view
      |> element("button[phx-click=open_refund_modal]", "Refund")
      |> render_click()

      view
      |> form("#refund-form", %{"refund_type" => "partial", "amount" => "15.00"})
      |> render_submit()

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == "partially_refunded"
      assert reloaded.refunded_amount_cents == 1500
    end

    test "another host's payment cannot be refunded via crafted id", %{conn: conn} do
      attacker = create_onboarded_user()
      victim = create_onboarded_user()

      insert(:connect_account,
        user: attacker,
        stripe_account_id: "acct_ATTACK",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      victim_payment = paid_payment_for(victim, %{stripe_account_id: "acct_VICTIM"})

      conn = log_in_user(conn, attacker)
      {:ok, view, _html} = live(conn, "/dashboard/payments")

      render_click(view, "open_refund_modal", %{"id" => victim_payment.id})

      refute render(view) =~ "Refund payment"
    end
  end
end
