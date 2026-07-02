defmodule TymeslotWeb.Dashboard.PaymentsSettingsTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.ResyncConnectAccount
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

  defp enable_payments do
    previous = Application.get_env(:tymeslot, :meeting_payments_enabled)
    Application.put_env(:tymeslot, :meeting_payments_enabled, true)
    on_exit(fn -> Application.put_env(:tymeslot, :meeting_payments_enabled, previous) end)
    :ok
  end

  describe "/dashboard/payments — when feature disabled" do
    setup do
      previous = Application.get_env(:tymeslot, :meeting_payments_enabled)
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :meeting_payments_enabled, previous) end)
      :ok
    end

    test "keeps the payments tab hidden inside the hub", %{conn: conn} do
      user = create_onboarded_user()
      conn = log_in_user(conn, user)

      # The hub falls back to the calendars tab when payments access is denied,
      # so the Stripe CTA never renders for a feature-disabled host.
      {:ok, _view, html} = live(conn, "/dashboard/integrations?tab=payments")

      refute html =~ "Connect Stripe"
    end

    test "the sidebar exposes the merged integrations entry, not a payments link",
         %{conn: conn} do
      user = create_onboarded_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/dashboard")

      refute html =~ "payments-nav-link"
      assert html =~ "/dashboard/integrations"
    end
  end

  describe "/dashboard/payments — when feature enabled" do
    setup do: enable_payments()

    test "surfaces the payments tab in the hub", %{conn: conn} do
      user = create_onboarded_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/dashboard/integrations")

      assert html =~ "/dashboard/integrations?tab=payments"
    end

    test "renders inside the dashboard shell with the sidebar", %{conn: conn} do
      user = create_onboarded_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/dashboard/integrations?tab=payments")

      assert html =~ "dashboard-sidebar"
      assert html =~ "Connect Stripe"
    end

    test "renders Connect Stripe CTA when no Stripe account", %{conn: conn} do
      user = create_onboarded_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, "/dashboard/integrations?tab=payments")
      assert html =~ "Connect Stripe"
    end
  end

  describe "/dashboard/payments — with active Stripe account" do
    setup do: enable_payments()

    # The status banner's full state machine (green / amber / red / not-connected)
    # is unit-tested in
    # `TymeslotWeb.Dashboard.PaymentsSettings.StatusCardTest`. This test only
    # proves the connected account is wired through to the rendered banner and
    # the payments section.
    test "renders the connected status banner for an active account", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_green",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/dashboard/integrations?tab=payments")

      assert html =~ "Connected and ready"
      assert html =~ "Recent payments"
    end

    test "enqueues a Stripe resync when the host returns from onboarding", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_return",
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false
      )

      conn = log_in_user(conn, user)

      {:ok, _view, _html} = live(conn, "/dashboard/integrations?tab=payments&return=1")

      assert_enqueued(
        worker: ResyncConnectAccount,
        args: %{stripe_account_id: "acct_return"}
      )
    end

    test "enqueues a Stripe resync when the host returns via refresh URL", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_refresh",
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false
      )

      conn = log_in_user(conn, user)

      {:ok, _view, _html} = live(conn, "/dashboard/integrations?tab=payments&refresh=1")

      assert_enqueued(
        worker: ResyncConnectAccount,
        args: %{stripe_account_id: "acct_refresh"}
      )
    end

    test "does not enqueue a Stripe resync without return/refresh params", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_quiet",
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      )

      conn = log_in_user(conn, user)
      {:ok, _view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      refute_enqueued(worker: ResyncConnectAccount)
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
      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      # The disconnect button opens an in-app confirmation modal; the actual
      # disconnect happens from the modal's confirm button.
      view |> element("button[phx-click=open_disconnect_modal]") |> render_click()
      assert has_element?(view, "#disconnect-modal")

      view |> element("#disconnect-modal button[phx-click=disconnect]") |> render_click()

      refute ConnectAccountQueries.live_for_user(user.id)
      refute has_element?(view, "#disconnect-modal")
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
      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      view
      |> element("button[phx-click=change_currency][phx-value-currency=gbp]")
      |> render_click()

      account = ConnectAccountQueries.live_for_user(user.id)
      assert account.default_currency == "gbp"

      reloaded = MeetingTypeQueries.get_meeting_type!(paid_mt.id)
      assert reloaded.payment_required == false
      assert reloaded.price_cents == nil
    end
  end

  describe "/dashboard/payments — incomplete onboarding" do
    setup do: enable_payments()

    test "prompts to finish onboarding and hides the operational sections", %{conn: conn} do
      user = create_onboarded_user()

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_incomplete",
        charges_enabled: false,
        payouts_enabled: false,
        details_submitted: false
      )

      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, "/dashboard/integrations?tab=payments")

      # The host can resume onboarding rather than landing on a dead-end card.
      assert html =~ "Finish connecting Stripe"
      assert html =~ "Continue onboarding"
      assert html =~ ~s(action="/dashboard/payments/connect")

      # The status conflation bug: an unsubmitted account must NOT claim to be
      # under Stripe review.
      refute html =~ "Pending Stripe review"

      # Operational sections are meaningless until onboarding is submitted.
      refute html =~ "Default currency"
      refute html =~ "Recent payments"
      refute html =~ "Disconnect Stripe"
    end
  end

  describe "/dashboard/payments — refund flow" do
    setup do: enable_payments()

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
      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

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
      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      view
      |> element("button[phx-click=open_refund_modal]", "Refund")
      |> render_click()

      view
      |> form("#refund-form", %{"refund_type" => "full"})
      |> render_submit()

      # The Stripe refund runs in start_async; await it before asserting.
      render_async(view)

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
      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      view
      |> element("button[phx-click=open_refund_modal]", "Refund")
      |> render_click()

      view
      |> form("#refund-form", %{"refund_type" => "partial", "amount" => "15.00"})
      |> render_submit()

      # The Stripe refund runs in start_async; await it before asserting.
      render_async(view)

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
      {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

      # Drive the component event directly with a crafted id; no rendered
      # button exists for a payment the attacker does not own.
      view
      |> with_target("#payments-settings")
      |> render_click("open_refund_modal", %{"id" => victim_payment.id})

      refute render(view) =~ "Refund payment"
    end
  end
end
