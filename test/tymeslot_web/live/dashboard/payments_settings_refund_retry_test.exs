defmodule TymeslotWeb.Dashboard.PaymentsSettingsRefundRetryTest do
  @moduledoc """
  Retrying a refund from the dashboard's refund dialog.

  A refund is decided against the balance the dialog shows, so its Stripe
  idempotency key names the payment and the total refunded when the dialog
  opened. A retry after a refund whose answer never arrived (the same dialog,
  a reopened one, a reloaded page) asks Stripe under the same key while
  nothing new is recorded; once a refund is recorded, a further one is a new
  key.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers, only: [setup_config: 2]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  setup :verify_on_exit!
  setup :set_mox_from_context

  setup %{conn: conn} do
    # The Core default checker honours the runtime flag whether or not an
    # overlay configures another.
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user)

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_REFUND",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )

    payment =
      insert(:paid_booking_payment,
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_REFUND"
      )

    %{conn: log_in_user(conn, user), payment: payment}
  end

  # Stripe makes the refund but its answer never arrives, and no webhook
  # has recorded it yet. The host closes the dialog, reloads the page and
  # tries again: the same refund, asked under the same key.
  test "a refund retried after a timeout, a reload and a reopened dialog is made once", %{
    conn: conn,
    payment: payment
  } do
    test_pid = self()

    expect(StripeAdapterMock, :create_refund, fn %{amount: 1500}, opts ->
      send(test_pid, {:refund_key, opts[:idempotency_key]})
      exit({:timeout, {GenServer, :call, []}})
    end)

    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")
    submit_partial_refund(view, "15.00")
    assert_received {:refund_key, first_key}

    view |> element("#refund-modal button", "Cancel") |> render_click()
    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

    # As Stripe answers: the refund already made for a key it has seen, a
    # second refund for one it has not.
    expect(StripeAdapterMock, :create_refund, fn %{amount: 1500}, opts ->
      refunded = if opts[:idempotency_key] == first_key, do: 1500, else: 3000
      {:ok, %{id: "re_partial", amount: 1500, charge: %{amount_refunded: refunded}}}
    end)

    submit_partial_refund(view, "15.00")

    assert %{refunded_amount_cents: 1500, status: :partially_refunded} =
             BookingPaymentQueries.get(payment.id)
  end

  test "a second refund of the same amount after the first is recorded is a new refund", %{
    conn: conn,
    payment: payment
  } do
    test_pid = self()

    expect(StripeAdapterMock, :create_refund, 2, fn %{amount: 1500}, opts ->
      send(test_pid, {:refund_key, opts[:idempotency_key]})
      {:ok, %{id: "re_partial", amount: 1500}}
    end)

    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")

    submit_partial_refund(view, "15.00")
    assert_received {:refund_key, first_key}
    submit_partial_refund(view, "15.00")
    assert_received {:refund_key, second_key}

    assert first_key != second_key
    assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 3000
  end

  defp submit_partial_refund(view, amount) do
    view
    |> element("button[phx-click=open_refund_modal]", "Refund")
    |> render_click()

    view
    |> form("#refund-form", %{"refund_type" => "partial", "amount" => amount})
    |> render_submit()

    render_async(view, 5_000)
  end
end
