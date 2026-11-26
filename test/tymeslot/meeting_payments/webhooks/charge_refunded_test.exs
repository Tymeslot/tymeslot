defmodule Tymeslot.MeetingPayments.Webhooks.ChargeRefundedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :integration

  # Every booking_payment is charged on this connected account, and every
  # event arrives from it, as Stripe delivers them for a genuine booking.
  @account "acct_TEST_HOST"

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.StripeWebhookFixtures
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # At the pinned API version the charge carries no refunds, so each event
  # lists them; these tests are about the total, so Stripe lists none.
  setup do
    StripeStub.stub(:list_refunds, StripeFixtures.list([]))
    :ok
  end

  describe "handle/1" do
    test "marks booking_payment refunded when full amount has been refunded" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_FULL"
        )

      event = refund_event("evt_FULL", "ch_FULL", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.last_event_id == "evt_FULL"
    end

    test "marks booking_payment partially_refunded when less than full" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_PART"
        )

      event = refund_event("evt_PART", "ch_PART", 2000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :partially_refunded
      assert reloaded.refunded_amount_cents == 2000
    end

    test "is idempotent when refunded_amount_cents already matches the event total" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :refunded,
          amount_cents: 5000,
          refunded_amount_cents: 5000,
          stripe_charge_id: "ch_DUP",
          last_event_id: "evt_PRIOR"
        )

      event = refund_event("evt_DUP", "ch_DUP", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      # Should still record the most recent event id
      assert reloaded.last_event_id == "evt_DUP"
    end

    test "is a no-op when the same event id has already been processed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 2000,
          stripe_charge_id: "ch_SAME",
          last_event_id: "evt_SAME"
        )

      event = refund_event("evt_SAME", "ch_SAME", 3500)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      # Untouched because last_event_id matched
      assert reloaded.refunded_amount_cents == 2000
    end

    test "returns :ok when no booking_payment matches the charge id" do
      event = refund_event("evt_NOMATCH", "ch_GHOST", 1000)
      assert :ok = ChargeRefunded.handle(event)
    end

    test "preserves status disputed when reconciling refund alongside a dispute" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_DISP"
        )

      event = refund_event("evt_DISP", "ch_DISP", 5000)

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.refunded_amount_cents == 5000
    end
  end

  describe "handle/1 after a partly lost dispute" do
    # Stripe's `amount_refunded` counts refunds only; the 3000 a lost
    # dispute took is no part of it.
    test "records a refund of the remainder and settles the payment" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 3000,
          disputed_lost_cents: 3000,
          stripe_charge_id: "ch_AFTER_LOSS"
        )

      assert :ok = ChargeRefunded.handle(refund_event("evt_AFTER_LOSS", "ch_AFTER_LOSS", 2000))

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.disputed_lost_cents == 3000
    end

    test "records a smaller refund on top of the loss" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 3000,
          disputed_lost_cents: 3000,
          stripe_charge_id: "ch_PART_AFTER_LOSS"
        )

      assert :ok =
               ChargeRefunded.handle(
                 refund_event("evt_PART_AFTER_LOSS", "ch_PART_AFTER_LOSS", 500)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :partially_refunded
      assert reloaded.refunded_amount_cents == 3500
    end
  end

  # A refund that races ahead of checkout.session.completed finds the row
  # only through the payment intent's metadata, read from Stripe.
  describe "handle/1 when the row is found only through Stripe" do
    setup do
      meeting = insert(:meeting)

      bp =
        insert(:booking_payment,
          meeting: meeting,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: nil,
          stripe_payment_intent_id: nil
        )

      event =
        put_in(
          refund_event("evt_BLIP", "ch_x", 5000),
          ["data", "object", "payment_intent"],
          "pi_x"
        )

      %{bp: bp, meeting: meeting, event: event}
    end

    test "a transient intent lookup makes charge.refunded answer retry_later", %{
      bp: bp,
      event: event
    } do
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "api_error"})

      assert {:error, :retry_later, %StripeError{type: "api_error"}} =
               ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.refunded_amount_cents == 0
      assert reloaded.status == :paid
      assert reloaded.last_event_id == nil
    end

    test "a redelivery after the blip succeeds", %{bp: bp, meeting: meeting, event: event} do
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "api_error"})
      assert {:error, :retry_later, _reason} = ChargeRefunded.handle(event)

      StripeStub.stub(
        :retrieve_payment_intent,
        StripeFixtures.object("payment_intent_with_latest_charge", %{
          "id" => "pi_x",
          "metadata" => %{"meeting_id" => meeting.id}
        })
      )

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.status == :refunded
    end

    test "an intent Stripe does not know is still acknowledged", %{bp: bp, event: event} do
      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "resource_missing"})

      assert :ok = ChargeRefunded.handle(event)
      assert Repo.reload!(bp).refunded_amount_cents == 0
    end

    # A redelivery would be refused the same way for as long as Stripe keeps
    # trying, so the event is acknowledged and an admin told it went unrecorded.
    test "a refused intent lookup is acknowledged with one admin alert", %{bp: bp, event: event} do
      capture_admin_alerts()

      StripeStub.stub(
        :retrieve_payment_intent,
        {403,
         %{
           "error" => %{
             "type" => "invalid_request_error",
             "message" => "The provided key does not have access to account acct_TEST_HOST."
           }
         }}
      )

      assert :ok = ChargeRefunded.handle(event)
      assert Repo.reload!(bp).refunded_amount_cents == 0

      assert_received {:send_alert, :connect_event_unmatched, alert}

      assert %{
               event_id: "evt_BLIP",
               charge_id: "ch_x",
               payment_intent_id: "pi_x",
               stripe_account_id: @account
             } = alert

      refute_received {:send_alert, _type, _alert}
    end
  end

  describe "handle/1 with an event from another connected account" do
    test "leaves the booking payment untouched" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_FOREIGN_REFUND"
        )

      event =
        "evt_FOREIGN_REFUND"
        |> refund_event("ch_FOREIGN_REFUND", 5000)
        |> Map.put("account", "acct_ATTACKER")

      assert :ok = ChargeRefunded.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :paid
      assert reloaded.refunded_amount_cents == 0
      assert reloaded.last_event_id == nil
    end
  end

  describe "handle/1 reconciling the charge's refunds" do
    setup do
      payment =
        insert(:paid_booking_payment,
          stripe_account_id: @account,
          stripe_charge_id: "ch_RECONCILE",
          amount_cents: 5_000
        )

      refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)

      %{payment: payment, refund: refund}
    end

    test "charge.refunded settles a pending outbox refund and emails the attendee once",
         %{payment: payment, refund: refund} do
      StripeStub.expect(:list_refunds, StripeFixtures.list([made_for(refund, 2_000)]))

      assert :ok = ChargeRefunded.handle(connect_charge_event(2_000))

      assert [%{query: query}] = StripeStub.requests(:list_refunds)
      assert query["charge"] == "ch_RECONCILE"

      assert %{status: :succeeded, stripe_refund_id: "re_RECONCILE"} =
               RefundQueries.get(refund.id)

      assert %{refunded_amount_cents: 2_000, status: :partially_refunded} = Repo.reload!(payment)
      assert [_one] = all_enqueued(worker: SendBookingPaymentRefunded)
      mark_emails_sent()

      assert {:ok, %{status: :succeeded}} = Refunds.execute(refund, [])

      assert StripeStub.requests(:create_refund) == []
      refute_enqueued(worker: SendBookingPaymentRefunded)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    end

    test "an attempt whose answer arrives after the webhook settled the refund sends no second email",
         %{payment: payment, refund: refund} do
      StripeStub.expect(:list_refunds, StripeFixtures.list([made_for(refund, 2_000)]))

      StripeStub.expect(:create_refund, fn request ->
        assert :ok = ChargeRefunded.handle(connect_charge_event(2_000))
        assert [_one] = all_enqueued(worker: SendBookingPaymentRefunded)
        mark_emails_sent()
        StripeStubResponses.refund(request, "re_RECONCILE")
      end)

      assert {:ok, %{status: :succeeded}} = Refunds.execute(refund, [])

      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "charge.refunded with embedded refunds makes no Stripe call",
         %{payment: payment, refund: refund} do
      event = embedded_event(refund, "re_EMBEDDED")

      assert :ok = ChargeRefunded.handle(event)

      assert StripeStub.requests() == []

      assert %{status: :succeeded, stripe_refund_id: "re_EMBEDDED"} =
               RefundQueries.get(refund.id)

      assert %{refunded_amount_cents: 2_000, status: :partially_refunded} = Repo.reload!(payment)
    end

    test "a dashboard refund is recorded as external", %{payment: payment, refund: refund} do
      Repo.delete!(refund)

      dashboard =
        "refund_with_charge"
        |> StripeFixtures.object(%{
          "id" => "re_DASHBOARD",
          "amount" => 1_500,
          "charge" => %{"amount_refunded" => 1_500}
        })
        |> Map.put("metadata", %{})

      StripeStub.expect(:list_refunds, StripeFixtures.list([dashboard]))

      assert :ok = ChargeRefunded.handle(connect_charge_event(1_500))

      assert [
               %{
                 source: :external,
                 status: :succeeded,
                 amount_cents: 1_500,
                 stripe_refund_id: "re_DASHBOARD"
               }
             ] = RefundQueries.list_for_payment(payment.id)

      assert %{refunded_amount_cents: 1_500, status: :partially_refunded} = Repo.reload!(payment)
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "a dashboard refund made during a dispute raises the total and keeps the payment disputed",
         %{payment: payment, refund: refund} do
      Repo.delete!(refund)
      payment = Repo.update!(Changeset.change(payment, status: :disputed))

      dashboard =
        "refund_with_charge"
        |> StripeFixtures.object(%{
          "id" => "re_DISPUTED_DASHBOARD",
          "amount" => 1_500,
          "charge" => %{"amount_refunded" => 1_500}
        })
        |> Map.put("metadata", %{})

      StripeStub.expect(:list_refunds, StripeFixtures.list([dashboard]))

      assert :ok = ChargeRefunded.handle(connect_charge_event(1_500))

      assert [%{source: :external, stripe_refund_id: "re_DISPUTED_DASHBOARD"}] =
               RefundQueries.list_for_payment(payment.id)

      assert %{refunded_amount_cents: 1_500, status: :disputed} = Repo.reload!(payment)
      assert Refunds.refusal(Repo.reload!(payment)) == {:error, :under_dispute}
    end

    test "settling a pending refund during a dispute keeps the payment disputed",
         %{payment: payment, refund: refund} do
      payment = Repo.update!(Changeset.change(payment, status: :disputed))
      StripeStub.expect(:list_refunds, StripeFixtures.list([made_for(refund, 2_000)]))

      assert :ok = ChargeRefunded.handle(connect_charge_event(2_000))

      assert %{status: :succeeded} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000, status: :disputed} = Repo.reload!(payment)
    end

    test "a transient refund list error retries the event", %{payment: payment, refund: refund} do
      event = connect_charge_event(2_000)
      StripeStub.expect(:list_refunds, 3, {:transport_error, :timeout})

      assert {:error, :retry_later, %StripeError{type: "api_connection_error"}} =
               ChargeRefunded.handle(event)

      assert %{status: :pending} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0, last_event_id: nil} = Repo.reload!(payment)

      StripeStub.expect(:list_refunds, StripeFixtures.list([made_for(refund, 2_000)]))

      assert :ok = ChargeRefunded.handle(event)

      assert %{status: :succeeded} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
      assert [_one] = all_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "a refund list Stripe refuses for good still records the total",
         %{payment: payment, refund: refund} do
      StripeStub.expect(
        :list_refunds,
        {403, %{"error" => %{"type" => "invalid_request_error", "code" => "account_invalid"}}}
      )

      assert :ok = ChargeRefunded.handle(connect_charge_event(2_000))

      assert %{status: :pending} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 2_000} = Repo.reload!(payment)
    end
  end

  # Stripe has since reported the refund failed, and refund.updated took it
  # off the total; this charge.refunded was sent before that.
  describe "handle/1 arriving after a refund it reports failed" do
    setup do
      payment =
        insert(:paid_booking_payment,
          stripe_account_id: @account,
          stripe_charge_id: "ch_RECONCILE",
          amount_cents: 5_000
        )

      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          status: :failed,
          failure_code: "refund_failed",
          stripe_refund_id: "re_RECONCILE",
          settled_at: DateTime.utc_now(:second)
        )

      %{payment: payment, refund: refund}
    end

    test "a stale embedded report does not put the refund back", %{
      payment: payment,
      refund: refund
    } do
      event = embedded_event(refund, "re_RECONCILE")

      assert :ok = ChargeRefunded.handle(event)

      assert %{status: :failed, failure_code: "refund_failed"} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "a stale embedded report does not put back a refund an attempt found failed", %{
      payment: payment
    } do
      refund = insert(:booking_payment_refund, booking_payment: payment, attempt: 1)

      failed =
        StripeFixtures.object("refund_with_charge", %{
          "id" => "re_ADOPT_FAILED",
          "amount" => refund.amount_cents,
          "status" => "failed",
          "metadata" => %{"tymeslot_refund_id" => refund.id},
          "charge" => %{"id" => "ch_RECONCILE", "amount_refunded" => 0}
        })

      StripeStub.expect(:list_refunds, StripeFixtures.list([failed]))

      assert {:error, :refund_failed} = Refunds.execute(refund, [])

      assert %{
               status: :failed,
               failure_code: "refund_failed",
               stripe_refund_id: "re_ADOPT_FAILED"
             } =
               RefundQueries.get(refund.id)

      assert :ok =
               refund
               |> embedded_event("re_ADOPT_FAILED", refund.amount_cents)
               |> ChargeRefunded.handle()

      assert %{status: :failed, failure_code: "refund_failed"} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "a stale event total gives way to the charge's current one", %{
      payment: payment,
      refund: refund
    } do
      failed =
        StripeFixtures.object("refund_with_charge", %{
          "id" => "re_RECONCILE",
          "amount" => 2_000,
          "status" => "failed",
          "metadata" => %{"tymeslot_refund_id" => refund.id},
          "charge" => %{"id" => "ch_RECONCILE", "amount_refunded" => 0}
        })

      StripeStub.expect(:list_refunds, StripeFixtures.list([failed]))

      assert :ok = ChargeRefunded.handle(connect_charge_event(2_000))

      assert %{status: :failed} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
    end
  end

  # A charge.refunded at the 2020-08-27 version, its refunds embedded: one,
  # made for `refund` as `stripe_refund_id`, reported succeeded.
  defp embedded_event(refund, stripe_refund_id, amount \\ 2_000) do
    "charge.refunded"
    |> StripeWebhookFixtures.event()
    |> Map.put("account", @account)
    |> update_in(["data", "object"], fn charge ->
      charge
      |> Map.merge(%{"id" => "ch_RECONCILE", "amount" => 5_000, "amount_refunded" => amount})
      |> put_in(["refunds", "data"], [
        %{
          "id" => stripe_refund_id,
          "object" => "refund",
          "amount" => amount,
          "charge" => "ch_RECONCILE",
          "metadata" => %{"tymeslot_refund_id" => refund.id},
          "status" => "succeeded"
        }
      ])
    end)
  end

  # The attendee's email went out, so the job no longer holds its unique
  # slot and a second one would be enqueued.
  defp mark_emails_sent do
    Repo.update_all(
      from(j in Oban.Job, where: j.worker == "Tymeslot.Workers.SendBookingPaymentRefunded"),
      set: [state: "completed"]
    )
  end

  # The refund Stripe made for `refund`, listed with its charge expanded.
  defp made_for(refund, charge_refunded) do
    StripeFixtures.object("refund_with_charge", %{
      "id" => "re_RECONCILE",
      "amount" => refund.amount_cents,
      "metadata" => %{"tymeslot_refund_id" => refund.id},
      "charge" => %{"id" => "ch_RECONCILE", "amount_refunded" => charge_refunded}
    })
  end

  defp connect_charge_event(amount_refunded) do
    charge =
      StripeFixtures.object("charge", %{
        "id" => "ch_RECONCILE",
        "amount" => 5_000,
        "amount_refunded" => amount_refunded
      })

    "charge.refunded"
    |> StripeWebhookFixtures.connect_event(charge, @account)
    |> Jason.decode!()
  end

  defp refund_event(event_id, charge_id, amount_refunded) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "charge.refunded",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => charge_id,
          "amount_refunded" => amount_refunded,
          "object" => "charge"
        }
      }
    }
  end
end
