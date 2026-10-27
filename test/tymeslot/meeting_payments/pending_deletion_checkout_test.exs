defmodule Tymeslot.MeetingPayments.PendingDeletionCheckoutTest do
  @moduledoc """
  A paid checkout left open when its host asks for their account to be
  deleted: the request cancels it, and a checkout that completes regardless
  is refunded rather than confirmed.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :auth
  @moduletag :integration

  import Mox, only: [expect: 3, stub: 3, verify_on_exit!: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.AccountDeletionCheckoutsWorker
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  @account "acct_PENDING_HOST"
  @password "Password123!"
  @opts [ip: "203.0.113.9", user_agent: "ExUnit"]

  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    with_config(:tymeslot, account_deletion_grace_days: 14, account_deletion_hook: nil)
    :ok
  end

  defp open_checkout(host, suffix) do
    meeting =
      insert(:meeting,
        status: "awaiting_payment",
        organizer_user_id: host.id,
        organizer_email: host.email
      )

    payment =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: host.id,
        stripe_account_id: @account,
        stripe_checkout_session_id: "cs_#{suffix}"
      )

    {meeting, payment}
  end

  defp completed(suffix, meeting) do
    %{
      "id" => "evt_#{suffix}",
      "account" => @account,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "cs_#{suffix}",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_#{suffix}",
          "payment_status" => "paid",
          "amount_total" => 5000,
          "currency" => "eur"
        }
      }
    }
  end

  defp expect_full_refund(payment, suffix) do
    stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
      {:ok, %{"latest_charge" => "ch_#{suffix}"}}
    end)

    expect(StripeAdapterMock, :create_refund, fn params, opts ->
      assert params.charge == "ch_#{suffix}"
      assert params.amount == payment.amount_cents
      assert opts[:connect_account] == @account
      {:ok, %{"id" => "re_#{suffix}"}}
    end)
  end

  defp request_deletion(host) do
    assert {:ok, pending} =
             Auth.request_account_deletion(host, %{"current_password" => @password}, @opts)

    pending
  end

  defp assert_cancelled(meeting, payment) do
    assert Repo.reload!(payment).status == "failed"
    assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)
  end

  test "requesting deletion queues the expiry of the host's open checkouts" do
    host = insert(:user)
    {meeting, payment} = open_checkout(host, "REQ_EXPIRE")

    request_deletion(host)
    assert_enqueued(worker: AccountDeletionCheckoutsWorker, args: %{user_id: host.id})
    assert Repo.reload!(payment).status == "pending"

    expect(StripeAdapterMock, :expire_checkout_session, fn "cs_REQ_EXPIRE", _opts ->
      {:ok, %{"id" => "cs_REQ_EXPIRE", "status" => "expired"}}
    end)

    assert %{success: 1} = Oban.drain_queue(queue: :payments)
    assert_cancelled(meeting, payment)
  end

  test "every booking is cancelled even when expiring one checkout raises" do
    host = insert(:user)
    {raising_meeting, raising_payment} = open_checkout(host, "REQ_RAISES")
    {other_meeting, other_payment} = open_checkout(host, "REQ_OTHER")

    request_deletion(host)

    stub(StripeAdapterMock, :expire_checkout_session, fn
      "cs_REQ_RAISES", _opts -> raise "Stripe is down"
      session, _opts -> {:ok, %{"id" => session, "status" => "expired"}}
    end)

    assert %{success: 1} = Oban.drain_queue(queue: :payments)
    assert_cancelled(raising_meeting, raising_payment)
    assert_cancelled(other_meeting, other_payment)
  end

  test "a host who restored the account keeps their checkouts" do
    host = insert(:user)
    {meeting, payment} = open_checkout(host, "RESTORED")

    pending = request_deletion(host)
    assert {:ok, _restored} = Auth.restore_account(pending)

    # Mox fails on any call to the adapter that is not expected.
    assert %{success: 1} = Oban.drain_queue(queue: :payments)
    assert Repo.reload!(payment).status == "pending"

    assert :ok = CheckoutSessionCompleted.handle(completed("RESTORED", meeting))
    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
    refute_enqueued(worker: RefundLatePayment)
  end

  # The guest is mid-payment when the host asks to leave, so Stripe will not
  # expire the session and the payment completes all the same.
  test "a checkout that completes after the host asked for deletion is refunded, not booked" do
    host = insert(:user)
    {meeting, payment} = open_checkout(host, "JOURNEY")

    request_deletion(host)

    expect(StripeAdapterMock, :expire_checkout_session, fn "cs_JOURNEY", _opts ->
      {:error, :session_in_payment}
    end)

    assert %{success: 1} = Oban.drain_queue(queue: :payments)

    expect_full_refund(payment, "JOURNEY")

    assert :ok = CheckoutSessionCompleted.handle(completed("JOURNEY", meeting))
    assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)
    assert_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: payment.id})

    assert %{success: 1} = Oban.drain_queue(queue: :payments)

    refunded = Repo.reload!(payment)
    assert refunded.status == "refunded"
    assert refunded.refunded_amount_cents == payment.amount_cents
    assert_enqueued(worker: SendBookingPaymentRefunded, args: %{booking_payment_id: payment.id})
    refute_enqueued(worker: CalendarEventWorker)
    assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)
  end

  # With no grace period the account, and its meetings, are gone before the
  # attendee's payment lands; the payment row survives with no meeting.
  test "a checkout that completes after the account was deleted is refunded in full once" do
    with_config(:tymeslot, :account_deletion_grace_days, 0)
    host = insert(:user)
    {meeting, payment} = open_checkout(host, "GONE")

    stub(StripeAdapterMock, :expire_checkout_session, fn _session, _opts ->
      {:error, :session_in_payment}
    end)

    request_deletion(host)
    Oban.drain_queue(queue: :default, with_scheduled: true)
    assert {:error, :not_found} = Auth.get_user(host.id)
    assert Repo.reload!(payment).meeting_id == nil

    expect_full_refund(payment, "GONE")

    assert :ok = CheckoutSessionCompleted.handle(completed("GONE", meeting))
    # Stripe's redelivery and the reconciler's replay schedule nothing more.
    assert :ok = CheckoutSessionCompleted.handle(completed("GONE", meeting))

    assert :ok =
             CheckoutSessionCompleted.handle(%{
               completed("GONE", meeting)
               | "id" => "reconcile:cs_GONE"
             })

    assert [_one] =
             all_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: payment.id})

    Oban.drain_queue(queue: :payments)

    refunded = Repo.reload!(payment)
    assert refunded.status == "refunded"
    assert refunded.refunded_amount_cents == payment.amount_cents
  end

  test "a completed checkout still awaiting payment is refused for a host pending deletion" do
    now = DateTime.utc_now(:second)

    host =
      insert(:user,
        deletion_requested_at: now,
        deletion_scheduled_at: DateTime.add(now, 14, :day)
      )

    {meeting, payment} = open_checkout(host, "AWAITING")

    assert :ok = CheckoutSessionCompleted.handle(completed("AWAITING", meeting))

    recorded = Repo.reload!(payment)
    assert recorded.status == "paid"
    assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)
    refute_enqueued(worker: CalendarEventWorker)

    # The reconciler replays the completion under its own event id.
    assert :ok =
             CheckoutSessionCompleted.handle(%{
               completed("AWAITING", meeting)
               | "id" => "reconcile:cs_AWAITING"
             })

    assert [_one] =
             all_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: payment.id})
  end
end
