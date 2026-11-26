defmodule TymeslotWeb.Dashboard.PaymentsSettingsRefundPendingTest do
  @moduledoc """
  A refund from the dashboard's refund dialog is recorded before Stripe is
  asked for it. One Stripe confirms is issued; one Stripe does not answer
  is submitted, shown as processing and finished by Tymeslot; while it is
  pending its share cannot be refunded again.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers, only: [setup_config: 2]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias Tymeslot.Workers.SendRefundFailed

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

    # Cancelled with the money still held, so it is on the outstanding list.
    meeting = insert(:meeting, status: :cancelled, cancelled_at: DateTime.utc_now(:second))

    payment =
      insert(:paid_booking_payment,
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_REFUND",
        meeting: meeting
      )

    %{conn: log_in_user(conn, user), user: user, payment: payment}
  end

  test "a host refund that Stripe confirms is issued", %{conn: conn, payment: payment} do
    StripeStub.expect(
      :create_refund,
      StripeFixtures.object("refund_with_charge", %{
        "id" => "re_FULL",
        "amount" => 5000,
        "charge" => %{"amount_refunded" => 5000}
      })
    )

    view = open(conn)
    html = submit_refund(view, payment, %{"refund_type" => "full"})

    assert html =~ "Refund issued. The attendee will receive a confirmation email."
    refute has_element?(view, "#refund-modal")

    assert %{status: :refunded, refunded_amount_cents: 5000} =
             BookingPaymentQueries.get(payment.id)
  end

  test "a host refund Stripe does not answer is submitted and finishes later", %{
    conn: conn,
    payment: payment
  } do
    # The client sends the lost call 3 times in all, under the same key.
    StripeStub.expect(:create_refund, 3, {:transport_error, :timeout})

    view = open(conn)
    html = submit_refund(view, payment, %{"refund_type" => "full"})

    assert html =~
             "Refund submitted. Stripe has not confirmed it yet; Tymeslot keeps trying and emails the attendee once it goes through."

    refute has_element?(view, "#refund-modal")
    assert has_element?(view, "#outstanding-refund-#{payment.id}", "Refund processing")
    assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0

    # Stripe answers the next attempt, which first finds no refund made.
    [refund] = RefundQueries.list_for_payment(payment.id)
    StripeStub.expect(:list_refunds, StripeFixtures.list([]))

    StripeStub.expect(
      :create_refund,
      StripeFixtures.object("refund_with_charge", %{
        "id" => "re_LATER",
        "amount" => 5000,
        "charge" => %{"amount_refunded" => 5000}
      })
    )

    assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 2)

    view = open(conn)
    refute has_element?(view, "#outstanding-refund-#{payment.id}")

    assert %{status: :refunded, refunded_amount_cents: 5000} =
             BookingPaymentQueries.get(payment.id)

    assert_enqueued(worker: SendBookingPaymentRefunded, args: %{booking_payment_id: payment.id})
  end

  test "a second refund while one is pending is refused", %{conn: conn, payment: payment} do
    # Installed so the requests can be read; none may be made.
    StripeStub.stub(:create_refund, {:error_fixture, "api_error"})
    view = open(conn)
    view |> element(refund_button(payment)) |> render_click()

    # Recorded meanwhile, from another tab, for all that remained.
    insert(:booking_payment_refund, booking_payment: payment, amount_cents: 5000)

    view |> form("#refund-form", %{"refund_type" => "full"}) |> render_submit()
    html = render(view)

    assert html =~ "A refund for this payment is already being processed."
    assert StripeStub.requests(:create_refund) == []
    assert [_only_the_pending_one] = RefundQueries.list_for_payment(payment.id)
  end

  test "the refund modal shows the amount being processed and caps the partial amount", %{
    conn: conn,
    payment: payment
  } do
    insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2000)
    StripeStub.stub(:create_refund, {:error_fixture, "api_error"})

    view = open(conn)

    view
    |> element("[data-testid=payments-table] button[phx-value-id='#{payment.id}']")
    |> render_click()

    assert has_element?(view, "#refund-pending", "€20.00 being processed")
    assert has_element?(view, "#refund-modal", "Full refund (€30.00)")
    assert has_element?(view, "#refund-modal input[name=amount][max='30.00']")
    refute has_element?(view, "#refund-modal button[type=submit][disabled]")

    view
    |> form("#refund-form", %{"refund_type" => "partial", "amount" => "40.00"})
    |> render_submit()

    assert has_element?(view, "#refund-modal", "Amount exceeds the remaining refundable balance.")
    assert StripeStub.requests(:create_refund) == []
  end

  test "a payment whose pending refunds hold all that remains cannot be submitted", %{
    conn: conn,
    payment: payment
  } do
    insert(:booking_payment_refund, booking_payment: payment, amount_cents: 5000)

    view = open(conn)

    view
    |> with_target("#payments-settings")
    |> render_click("open_refund_modal", %{"id" => payment.id})

    assert has_element?(view, "#refund-pending", "€50.00 being processed")
    assert has_element?(view, "#refund-modal button[type=submit][disabled]")
  end

  # A pending refund is no reason to open the dialog on a payment Tymeslot
  # could not refund anyway.
  test "a payment past the refund window with a pending refund is still refused", %{
    conn: conn,
    payment: payment
  } do
    payment
    |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day))
    |> Repo.update!()

    insert(:booking_payment_refund, booking_payment: payment, amount_cents: 5000)

    view = open(conn)

    view
    |> with_target("#payments-settings")
    |> render_click("open_refund_modal", %{"id" => payment.id})

    refute has_element?(view, "#refund-modal")
    assert render(view) =~ "This payment can no longer be refunded from Tymeslot."
  end

  # The refund and its retrying job are recorded before Stripe is called, so
  # a crash during the call leaves the refund pending: the host must see it
  # submitted, not be told to try again and refund a second time.
  test "a refund whose dialog task crashes after recording it is shown as submitted", %{
    conn: conn,
    payment: payment
  } do
    StripeStub.stub(:create_refund, fn _request -> raise "connection reset mid-request" end)

    view = open(conn)

    {html, _log} =
      with_log(fn -> submit_refund(view, payment, %{"refund_type" => "full"}) end)

    assert html =~
             "Refund submitted. Stripe has not confirmed it yet; Tymeslot keeps trying and emails the attendee once it goes through."

    refute html =~ "Something went wrong while issuing the refund."
    refute has_element?(view, "#refund-modal")
    assert has_element?(view, "#outstanding-refund-#{payment.id}", "Refund processing")
    assert [%{status: :pending, amount_cents: 5000}] = RefundQueries.list_for_payment(payment.id)
  end

  test "a refund Stripe declines says so and emails the host", %{conn: conn, payment: payment} do
    StripeStub.expect(:create_refund, {:error_fixture, "invalid_request_error"})

    view = open(conn)
    html = submit_refund(view, payment, %{"refund_type" => "full"})

    assert html =~ "Stripe declined this refund. Check the payment in your Stripe dashboard."
    assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0
    assert [refund] = RefundQueries.list_for_payment(payment.id)
    assert_enqueued(worker: SendRefundFailed, args: %{refund_id: refund.id})
  end

  defp open(conn) do
    {:ok, view, _html} = live(conn, "/dashboard/integrations?tab=payments")
    view
  end

  defp refund_button(payment),
    do: "#outstanding-refunds button[phx-value-id='#{payment.id}']"

  defp submit_refund(view, payment, params) do
    view |> element(refund_button(payment)) |> render_click()
    view |> form("#refund-form", params) |> render_submit()
    render_async(view, 5_000)
    # The flash reaches the page through a message the view handles next.
    render(view)
  end
end
