defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedOwnershipTest do
  @moduledoc false
  # A `checkout.session.completed` event only confirms a booking when it is
  # that booking's own session: from the connected account the booking was
  # charged on, for the price and currency snapshotted on the row.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.EmailWorker

  describe "handle/1 refuses a session that is not this booking's payment" do
    setup do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "pending",
          amount_cents: 5000,
          currency: "eur",
          stripe_checkout_session_id: nil
        )

      %{meeting: meeting, bp: bp}
    end

    # Another host on a Standard account can create and pay a session on
    # their own account with any client_reference_id they like.
    test "ignores a paid session from another connected account", %{meeting: meeting, bp: bp} do
      event =
        "evt_FOREIGN_ACCT"
        |> completed_event(%{"id" => "cs_FOREIGN", "client_reference_id" => meeting.id})
        |> Map.put("account", "acct_ATTACKER")

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert_untouched(meeting, bp)
    end

    test "ignores a session whose amount differs from the booking's price",
         %{meeting: meeting, bp: bp} do
      event =
        completed_event("evt_CHEAP", %{
          "id" => "cs_CHEAP",
          "client_reference_id" => meeting.id,
          "amount_total" => 50
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert_untouched(meeting, bp)
    end

    # A paid session that does not match the booking's price is either
    # tampering or a bug in checkout creation, and money has moved either
    # way, so it is logged as an error for someone to act on.
    test "logs a price mismatch as an error", %{meeting: meeting, bp: bp} do
      LogCapture.attach()

      event =
        completed_event("evt_CHEAP_LOGGED", %{
          "id" => "cs_CHEAP_LOGGED",
          "client_reference_id" => meeting.id,
          "amount_total" => 50
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert %{level: :error, meta: meta} =
               LogCapture.await_log("amount or currency does not match the booking")

      assert meta.payment_id == bp.id
      assert meta.amount_total == 50
    end

    test "ignores a session whose currency differs from the booking's",
         %{meeting: meeting, bp: bp} do
      event =
        completed_event("evt_CURRENCY", %{
          "id" => "cs_CURRENCY",
          "client_reference_id" => meeting.id,
          "currency" => "jpy"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert_untouched(meeting, bp)
    end

    test "ignores a session other than the one attached to the booking",
         %{meeting: meeting, bp: bp} do
      bp =
        bp |> Changeset.change(stripe_checkout_session_id: "cs_ATTACHED") |> Repo.update!()

      event =
        completed_event("evt_WRONG_SESSION", %{
          "id" => "cs_NOT_ATTACHED",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert_untouched(meeting, bp)
    end
  end

  describe "handle/1 matching the booking's price" do
    # Stripe reports ISO currency codes in lower case, but the comparison
    # must not depend on it: the same currency in a different case is the
    # same price.
    test "confirms a session whose currency differs only in case" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "pending",
          amount_cents: 5000,
          currency: "eur",
          stripe_checkout_session_id: "cs_UPPER"
        )

      event =
        completed_event("evt_UPPER", %{
          "id" => "cs_UPPER",
          "client_reference_id" => meeting.id,
          "currency" => "EUR"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert %{status: "paid", last_event_id: "evt_UPPER"} = Repo.reload!(bp)
      assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
    end
  end

  defp assert_untouched(meeting, bp) do
    reloaded = Repo.reload!(bp)
    assert reloaded.status == "pending"
    assert reloaded.last_event_id == nil
    assert {:ok, %{status: "awaiting_payment"}} = MeetingQueries.get_meeting(meeting.id)
    refute_enqueued(worker: EmailWorker)
  end

  defp completed_event(event_id, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" =>
          Map.merge(
            %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"},
            object
          )
      }
    }
  end
end
