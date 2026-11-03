defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreatedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  # Every booking_payment is charged on this connected account, and every
  # event arrives from it, as Stripe delivers them for a genuine booking.
  @account "acct_TEST_HOST"

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendChargeDisputeOpened

  describe "handle/1" do
    test "transitions a paid booking_payment to disputed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_DISPUTED"
        )

      event = dispute_event("evt_DISPUTE", "ch_DISPUTED")

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.last_event_id == "evt_DISPUTE"
    end

    test "preserves refunded_amount_cents on a partially_refunded booking_payment" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 1500,
          stripe_charge_id: "ch_PART_DISP"
        )

      event = dispute_event("evt_PART_DISP", "ch_PART_DISP")

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.refunded_amount_cents == 1500
    end

    test "is idempotent — replaying the same event id is a no-op" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_REPLAY_DISP",
          last_event_id: "evt_REPLAY_DISP"
        )

      event = dispute_event("evt_REPLAY_DISP", "ch_REPLAY_DISP")

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.last_event_id == "evt_REPLAY_DISP"
    end

    test "returns :ok when no booking_payment matches the charge id" do
      event = dispute_event("evt_NOMATCH", "ch_GHOST")
      assert :ok = ChargeDisputeCreated.handle(event)
    end

    test "matches by payment_intent when the charge id is not yet on the row (race)" do
      # The dispute can race ahead of checkout.session.completed, before the
      # charge id is backfilled. The row still carries the payment_intent id
      # (captured at session creation), so the dispute must match on that.
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: nil,
          stripe_payment_intent_id: "pi_RACE_DISP"
        )

      event = %{
        "id" => "evt_RACE_DISP",
        "account" => @account,
        "type" => "charge.dispute.created",
        "created" => System.os_time(:second),
        "data" => %{
          "object" => %{
            "id" => "dp_RACE_DISP",
            "charge" => "ch_NOT_YET_LINKED",
            "payment_intent" => "pi_RACE_DISP",
            "object" => "dispute",
            "amount" => 5000,
            "reason" => "fraudulent"
          }
        }
      }

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.last_event_id == "evt_RACE_DISP"
    end

    test "enqueues the host dispute email after marking disputed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_EMAIL_DISP"
        )

      event = dispute_event("evt_EMAIL_DISP", "ch_EMAIL_DISP")

      assert :ok = ChargeDisputeCreated.handle(event)

      assert_enqueued(
        worker: SendChargeDisputeOpened,
        args: %{booking_payment_id: bp.id, reason: "fraudulent"}
      )
    end

    test "does not enqueue the email when replaying the same event id" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_REPLAY_NOEMAIL",
          last_event_id: "evt_REPLAY_NOEMAIL"
        )

      event = dispute_event("evt_REPLAY_NOEMAIL", "ch_REPLAY_NOEMAIL")

      assert :ok = ChargeDisputeCreated.handle(event)

      refute_enqueued(
        worker: SendChargeDisputeOpened,
        args: %{booking_payment_id: bp.id}
      )
    end
  end

  # A dispute can reach Stripe's created event already over in the host's
  # favour, and no closed event need follow it.
  describe "handle/1 with a dispute already settled for the host" do
    for status <- ["warning_closed", "prevented"] do
      test "#{status} leaves the payment paid and does not email the host" do
        bp =
          insert(:booking_payment,
            stripe_account_id: @account,
            status: :paid,
            amount_cents: 5000,
            stripe_charge_id: "ch_SETTLED_#{unquote(status)}"
          )

        event =
          dispute_event("evt_SETTLED_#{unquote(status)}", "ch_SETTLED_#{unquote(status)}",
            status: unquote(status)
          )

        assert :ok = ChargeDisputeCreated.handle(event)

        reloaded = Repo.reload!(bp)
        assert reloaded.status == :paid
        assert reloaded.last_event_id == nil
        refute_enqueued(worker: SendChargeDisputeOpened)
      end
    end

    test "an open inquiry is still recorded as disputed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_INQUIRY_OPEN"
        )

      event =
        dispute_event("evt_INQUIRY_OPEN", "ch_INQUIRY_OPEN", status: "warning_needs_response")

      assert :ok = ChargeDisputeCreated.handle(event)

      assert Repo.reload!(bp).status == :disputed
      assert_enqueued(worker: SendChargeDisputeOpened, args: %{booking_payment_id: bp.id})
    end
  end

  # Stripe can deliver `created` after the `closed` that settled the same
  # dispute (out of order, or retrying a failed delivery). The late payload
  # still carries the open status it was created with.
  describe "handle/1 with a dispute the payment already records as closed" do
    test "a created delivered after its closed leaves the payment paid and emails no one" do
      bp = paid_payment("ch_CLOSED_FIRST")

      assert :ok =
               ChargeDisputeClosed.handle(
                 closed_event("evt_CF_CLOSED", "ch_CLOSED_FIRST", "dp_CLOSED_FIRST", "won")
               )

      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_CF_CREATED", "ch_CLOSED_FIRST", dispute_id: "dp_CLOSED_FIRST")
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :paid
      assert reloaded.last_event_id == "evt_CF_CLOSED"
      refute_enqueued(worker: SendChargeDisputeOpened)
    end

    test "a retried created after created and closed leaves the payment paid and emails once" do
      bp = paid_payment("ch_RETRIED")

      created = dispute_event("evt_RT_CREATED", "ch_RETRIED", dispute_id: "dp_RETRIED")
      assert :ok = ChargeDisputeCreated.handle(created)
      assert Repo.reload!(bp).status == :disputed

      assert :ok =
               ChargeDisputeClosed.handle(
                 closed_event("evt_RT_CLOSED", "ch_RETRIED", "dp_RETRIED", "won")
               )

      # Stripe retries the first delivery under the same event id; the
      # closed event has since replaced it as `last_event_id`.
      assert :ok = ChargeDisputeCreated.handle(created)

      assert Repo.reload!(bp).status == :paid
      assert [_one] = all_enqueued(worker: SendChargeDisputeOpened)
    end

    test "a new dispute after a closed one is still marked disputed" do
      bp = paid_payment("ch_SECOND")

      assert :ok =
               ChargeDisputeClosed.handle(
                 closed_event("evt_SD_CLOSED", "ch_SECOND", "dp_FIRST", "warning_closed")
               )

      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_SD_CREATED", "ch_SECOND", dispute_id: "dp_SECOND")
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.stripe_dispute_id == "dp_SECOND"
      assert reloaded.dispute_closed_at == nil
      assert_enqueued(worker: SendChargeDisputeOpened, args: %{booking_payment_id: bp.id})
    end
  end

  describe "handle/1 with an event from another connected account" do
    test "neither marks the booking disputed nor emails the host" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_FOREIGN_DISP"
        )

      event =
        "evt_FOREIGN_DISP"
        |> dispute_event("ch_FOREIGN_DISP")
        |> Map.put("account", "acct_ATTACKER")

      assert :ok = ChargeDisputeCreated.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :paid
      assert reloaded.last_event_id == nil
      refute_enqueued(worker: SendChargeDisputeOpened)
    end
  end

  defp dispute_event(event_id, charge_id, opts \\ []) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "charge.dispute.created",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => Keyword.get(opts, :dispute_id, "dp_#{event_id}"),
          "charge" => charge_id,
          "object" => "dispute",
          "amount" => 5000,
          "reason" => "fraudulent",
          "status" => Keyword.get(opts, :status, "needs_response")
        }
      }
    }
  end

  defp paid_payment(charge_id) do
    insert(:booking_payment,
      stripe_account_id: @account,
      status: :paid,
      amount_cents: 5000,
      stripe_charge_id: charge_id
    )
  end

  defp closed_event(event_id, charge_id, dispute_id, status) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "charge.dispute.closed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => dispute_id,
          "object" => "dispute",
          "charge" => charge_id,
          "amount" => 5000,
          "status" => status
        }
      }
    }
  end
end
