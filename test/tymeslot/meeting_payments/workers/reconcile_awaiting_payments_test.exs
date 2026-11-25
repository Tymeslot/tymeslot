defmodule Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPaymentsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  defp insert_stale_pending(opts) do
    inserted_at =
      Keyword.get_lazy(opts, :inserted_at, fn ->
        DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
      end)

    meeting = insert(:meeting, Keyword.get(opts, :meeting, status: :awaiting_payment))

    bp =
      insert(:booking_payment,
        meeting: meeting,
        status: :pending,
        stripe_account_id: "acct_TEST",
        stripe_checkout_session_id: Keyword.get(opts, :session_id, "cs_STALE")
      )

    # Backdate inserted_at to make the row stale.
    {1, _result} =
      Repo.update_all(
        from(b in BookingPaymentSchema, where: b.id == ^bp.id),
        set: [inserted_at: inserted_at]
      )

    {meeting, Repo.reload!(bp)}
  end

  defp paid_session(id, meeting, bp, payment_intent) do
    StripeFixtures.object("checkout_session_paid", %{
      "id" => id,
      "payment_status" => "paid",
      "status" => "complete",
      "client_reference_id" => meeting.id,
      "payment_intent" => payment_intent,
      "amount_total" => bp.amount_cents,
      "currency" => bp.currency
    })
  end

  describe "perform/1" do
    test "polls Stripe and reconciles a paid session to paid+confirmed" do
      {meeting, bp} = insert_stale_pending(session_id: "cs_PAID")

      StripeStub.expect(
        :retrieve_checkout_session,
        paid_session("cs_PAID", meeting, bp, "pi_RECONCILED")
      )

      assert {:ok, %{reconciled: 1, skipped: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})

      assert [%{path: "/v1/checkout/sessions/cs_PAID", headers: headers}] =
               StripeStub.requests(:retrieve_checkout_session)

      assert headers["stripe-account"] == "acct_TEST"

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == :paid
      assert reloaded.paid_at
      assert reloaded.stripe_payment_intent_id == "pi_RECONCILED"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == :confirmed
    end

    test "polls Stripe and reconciles an expired session to failed+expired" do
      {meeting, bp} = insert_stale_pending(session_id: "cs_EXPIRED")

      StripeStub.expect(
        :retrieve_checkout_session,
        StripeFixtures.object("checkout_session_expired", %{
          "id" => "cs_EXPIRED",
          "payment_status" => "unpaid",
          "status" => "expired",
          "client_reference_id" => meeting.id
        })
      )

      assert {:ok, %{reconciled: 1, skipped: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})

      assert [%{path: "/v1/checkout/sessions/cs_EXPIRED", headers: headers}] =
               StripeStub.requests(:retrieve_checkout_session)

      assert headers["stripe-account"] == "acct_TEST"

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == :failed

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == :expired
    end

    test "a handler failure is logged and leaves the payment pending for the next sweep" do
      {meeting, bp} = insert_stale_pending(session_id: "cs_HANDLER_FAILS")

      StripeStub.expect(
        :retrieve_checkout_session,
        paid_session("cs_HANDLER_FAILS", meeting, bp, "pi_HANDLER_FAILS")
      )

      # The handler's calendar enqueue fails, so it answers `{:error, :retry_later, _}`.
      :meck.new(Oban, [:passthrough])
      :meck.expect(Oban, :insert, fn _job -> {:error, :queue_not_available} end)

      log =
        try do
          capture_log(fn ->
            assert {:ok, %{reconciled: 1, skipped: 0}} =
                     perform_job(ReconcileAwaitingPayments, %{})
          end)
        after
          :meck.unload(Oban)
        end

      assert log =~ "ReconcileAwaitingPayments handler failed"
      assert BookingPaymentQueries.get(bp.id).status == :pending
    end

    # The host cancelled the booking while its checkout was open, and the
    # attendee paid all the same: the sweep records the payment and its
    # refund once, and the row is off its list from then on.
    test "settles a paid session of a cancelled booking once, then leaves it" do
      {meeting, bp} =
        insert_stale_pending(
          session_id: "cs_CANCELLED_PAID",
          meeting: [status: :cancelled, cancelled_at: DateTime.utc_now(:second)]
        )

      StripeStub.expect(
        :retrieve_checkout_session,
        paid_session("cs_CANCELLED_PAID", meeting, bp, "pi_CANCELLED_PAID")
      )

      assert {:ok, %{reconciled: 1}} = perform_job(ReconcileAwaitingPayments, %{})

      assert %{status: :paid} = BookingPaymentQueries.get(bp.id)
      assert [%{source: :late_payment, amount_cents: 5000}] = Repo.all(RefundSchema)
      assert {:ok, %{status: :cancelled}} = MeetingQueries.get_meeting(meeting.id)

      # No Stripe stub left: a second poll of the session fails the test.
      assert {:ok, %{reconciled: 0, skipped: 0, errors: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})

      assert [%{path: "/v1/checkout/sessions/cs_CANCELLED_PAID"}] =
               StripeStub.requests(:retrieve_checkout_session)
    end

    test "leaves still-open sessions alone" do
      {meeting, bp} = insert_stale_pending(session_id: "cs_OPEN")

      StripeStub.expect(
        :retrieve_checkout_session,
        StripeFixtures.object("checkout_session_payment", %{
          "id" => "cs_OPEN",
          "payment_status" => "unpaid",
          "status" => "open",
          "client_reference_id" => meeting.id
        })
      )

      assert {:ok, %{reconciled: 0, skipped: 1}} =
               perform_job(ReconcileAwaitingPayments, %{})

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == :pending

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == :awaiting_payment
    end

    test "skips fresh pending payments" do
      now = DateTime.utc_now(:second)

      insert_stale_pending(
        inserted_at: DateTime.add(now, -10, :minute),
        session_id: "cs_FRESH"
      )

      # No Stripe stub: any request fails the test.
      assert {:ok, %{reconciled: 0, skipped: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})
    end

    test "tolerates Stripe errors and reports them in the result" do
      {_meeting, bp} = insert_stale_pending(session_id: "cs_ERR")

      StripeStub.stub(:retrieve_checkout_session, {:error_fixture, "api_error"})

      assert {:ok, %{reconciled: 0, skipped: 0, errors: 1}} =
               perform_job(ReconcileAwaitingPayments, %{})

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == :pending
    end
  end
end
