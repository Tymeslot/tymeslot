defmodule Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPaymentsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Ecto.Query
  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo

  setup :verify_on_exit!
  setup :set_mox_from_context

  defp insert_stale_pending(opts) do
    inserted_at =
      Keyword.get_lazy(opts, :inserted_at, fn ->
        DateTime.utc_now() |> DateTime.add(-2, :hour) |> DateTime.truncate(:second)
      end)

    meeting = insert(:meeting, status: "awaiting_payment")

    bp =
      insert(:booking_payment,
        meeting: meeting,
        status: "pending",
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

  describe "perform/1" do
    test "polls Stripe and reconciles a paid session to paid+confirmed" do
      {meeting, bp} = insert_stale_pending(session_id: "cs_PAID")

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_PAID", opts ->
        assert opts[:connect_account] == "acct_TEST"

        {:ok,
         %{
           "id" => "cs_PAID",
           "payment_status" => "paid",
           "status" => "complete",
           "client_reference_id" => meeting.id,
           "payment_intent" => "pi_RECONCILED"
         }}
      end)

      assert {:ok, %{reconciled: 1, skipped: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == "paid"
      assert reloaded.paid_at
      assert reloaded.stripe_payment_intent_id == "pi_RECONCILED"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "confirmed"
    end

    test "polls Stripe and reconciles an expired session to failed+expired" do
      {meeting, bp} = insert_stale_pending(session_id: "cs_EXPIRED")

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_EXPIRED", opts ->
        assert opts[:connect_account] == "acct_TEST"

        {:ok,
         %{
           "id" => "cs_EXPIRED",
           "payment_status" => "unpaid",
           "status" => "expired",
           "client_reference_id" => meeting.id
         }}
      end)

      assert {:ok, %{reconciled: 1, skipped: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == "failed"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "expired"
    end

    test "leaves still-open sessions alone" do
      {meeting, bp} = insert_stale_pending(session_id: "cs_OPEN")

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_OPEN", _opts ->
        {:ok,
         %{
           "id" => "cs_OPEN",
           "payment_status" => "unpaid",
           "status" => "open",
           "client_reference_id" => meeting.id
         }}
      end)

      assert {:ok, %{reconciled: 0, skipped: 1}} =
               perform_job(ReconcileAwaitingPayments, %{})

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == "pending"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "awaiting_payment"
    end

    test "skips fresh pending payments" do
      now = DateTime.utc_now(:second)

      insert_stale_pending(
        inserted_at: DateTime.add(now, -10, :minute),
        session_id: "cs_FRESH"
      )

      # No Stripe call expected — Mox `verify_on_exit!` enforces this.
      assert {:ok, %{reconciled: 0, skipped: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})
    end

    test "reconciles a paid session when Stripe returns a real stripity struct" do
      # Regression: production stripity_stripe returns an atom-keyed
      # %Stripe.Checkout.Session{} struct, not a string-keyed map. Before the
      # adapter-seam normalisation, no dispatch clause matched and stale rows
      # never recovered. Feeding the real struct shape proves the worker now
      # reconciles regardless of adapter.
      {meeting, bp} = insert_stale_pending(session_id: "cs_STRUCT_PAID")

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_STRUCT_PAID", _opts ->
        {:ok,
         %Stripe.Checkout.Session{
           id: "cs_STRUCT_PAID",
           payment_status: "paid",
           status: "complete",
           client_reference_id: meeting.id,
           payment_intent: "pi_STRUCT_PAID"
         }}
      end)

      assert {:ok, %{reconciled: 1, skipped: 0}} =
               perform_job(ReconcileAwaitingPayments, %{})

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == "paid"
      assert reloaded.stripe_payment_intent_id == "pi_STRUCT_PAID"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "confirmed"
    end

    test "tolerates Stripe errors and reports them in the result" do
      {_meeting, bp} = insert_stale_pending(session_id: "cs_ERR")

      expect(StripeAdapterMock, :retrieve_checkout_session, fn "cs_ERR", _opts ->
        {:error, %{message: "boom"}}
      end)

      assert {:ok, %{reconciled: 0, skipped: 0, errors: 1}} =
               perform_job(ReconcileAwaitingPayments, %{})

      reloaded = BookingPaymentQueries.get(bp.id)
      assert reloaded.status == "pending"
    end
  end
end
