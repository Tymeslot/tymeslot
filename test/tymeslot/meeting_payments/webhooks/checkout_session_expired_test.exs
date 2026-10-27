defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpiredTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  # Every booking_payment is charged on this connected account, and every
  # event arrives from it, as Stripe delivers them for a genuine booking.
  @account "acct_TEST_HOST"

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  describe "handle/1" do
    test "marks the booking_payment failed and the meeting expired" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_EXPIRED"
        )

      event =
        expired_event("evt_EXPIRED", %{
          "id" => "cs_EXPIRED",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "failed"
      assert reloaded.last_event_id == "evt_EXPIRED"

      {:ok, meeting} = MeetingQueries.get_meeting(meeting.id)
      assert meeting.status == "expired"
    end

    test "is idempotent — replaying the same event id is a no-op" do
      meeting = insert(:meeting, status: "expired")

      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_REPLAY",
          last_event_id: "evt_REPLAY"
        )

      event =
        expired_event("evt_REPLAY", %{
          "id" => "cs_REPLAY",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "failed"
      assert reloaded.last_event_id == "evt_REPLAY"
    end

    test "does not enqueue any side-effect jobs" do
      meeting = insert(:meeting, status: "awaiting_payment")

      _bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_SILENT"
        )

      event =
        expired_event("evt_SILENT", %{
          "id" => "cs_SILENT",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)
      refute_enqueued(worker: Tymeslot.Workers.EmailWorker)
    end

    test "returns :ok when no booking_payment matches" do
      meeting = insert(:meeting, status: "awaiting_payment")

      event =
        expired_event("evt_NOMATCH", %{
          "id" => "cs_NOPE",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)
    end

    test "falls back to checkout_session_id lookup when client_reference_id yields no row" do
      # Regression for W3: by_meeting_id returns nil (stale/mismatched reference)
      # but the session IS in the DB. The handler must fall back to
      # by_checkout_session and still expire the payment and free the slot.
      meeting_a = insert(:meeting, status: "awaiting_payment")
      meeting_b = insert(:meeting, status: "awaiting_payment")

      # booking_payment belongs to meeting_a by session id, but the event
      # arrives with meeting_b as the client_reference_id, so by_meeting_id
      # returns nil — only the session fallback can find this row.
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting_a,
          status: "pending",
          stripe_checkout_session_id: "cs_FALLBACK_W3"
        )

      event =
        expired_event("evt_FALLBACK_W3", %{
          "id" => "cs_FALLBACK_W3",
          "client_reference_id" => meeting_b.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "failed"
      assert reloaded.last_event_id == "evt_FALLBACK_W3"
    end

    test "broadcasts :expired via PubSub after a successful transition" do
      meeting = insert(:meeting, status: "awaiting_payment")

      _bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_BCAST_EXPIRED"
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "meeting_payment:#{meeting.id}")

      event =
        expired_event("evt_BCAST_EXPIRED", %{
          "id" => "cs_BCAST_EXPIRED",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)
      assert_receive :expired, 1_000
    end

    # An organiser can cancel a booking still awaiting payment, and that
    # cancel says nothing on the payment topic, so the attendee waiting on
    # the payment hears of it only when the payment itself fails.
    test "tells the waiting attendee when the payment fails behind a cancelled meeting" do
      meeting = insert(:meeting, status: "cancelled")

      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_CANCELLED_PENDING"
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, MeetingPayments.payment_topic(meeting.id))

      event =
        expired_event("evt_CANCELLED_PENDING", %{
          "id" => "cs_CANCELLED_PENDING",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)
      assert_receive :expired, 1_000

      assert Repo.reload!(bp).status == "failed"
      assert {:ok, %{status: "cancelled"}} = MeetingQueries.get_meeting(meeting.id)
    end
  end

  # A Stripe disconnect fails pending payments and expires their meetings in
  # separate writes; when the meeting write fails, the slot stays held behind
  # a payment that is failed already.
  describe "handle/1 for a payment failed already" do
    test "expires a meeting still awaiting payment, once" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "failed",
          last_event_id: "disconnect",
          stripe_checkout_session_id: "cs_FAILED_HELD"
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "meeting_payment:#{meeting.id}")
      object = %{"id" => "cs_FAILED_HELD", "client_reference_id" => meeting.id}

      assert :ok = CheckoutSessionExpired.handle(expired_event("evt_FAILED_HELD", object))

      assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)
      assert_receive :expired, 1_000

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "failed"
      assert reloaded.last_event_id == "disconnect"

      assert :ok = CheckoutSessionExpired.handle(expired_event("evt_FAILED_HELD_2", object))
      refute_receive :expired, 100
    end

    # The disconnect's meeting write can fail because the row no longer
    # passes the full meeting validation (here a solo meeting with no
    # attendee name, as older rows can carry). Expiring it must not depend
    # on that validation, or the expiry fails the same way and the event is
    # retried instead of acknowledged.
    test "expires a meeting whose other fields no longer pass validation" do
      meeting = insert(:meeting, status: "awaiting_payment")

      Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id), set: [attendee_name: nil])

      insert(:booking_payment,
        stripe_account_id: @account,
        meeting: meeting,
        status: "failed",
        stripe_checkout_session_id: "cs_FAILED_LEGACY"
      )

      object = %{"id" => "cs_FAILED_LEGACY", "client_reference_id" => meeting.id}

      assert :ok = CheckoutSessionExpired.handle(expired_event("evt_FAILED_LEGACY", object))
      assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)
    end

    test "leaves a meeting that has moved on" do
      meeting = insert(:meeting, status: "cancelled")

      insert(:booking_payment,
        stripe_account_id: @account,
        meeting: meeting,
        status: "failed",
        stripe_checkout_session_id: "cs_FAILED_GONE"
      )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "meeting_payment:#{meeting.id}")

      event =
        expired_event("evt_FAILED_GONE", %{
          "id" => "cs_FAILED_GONE",
          "client_reference_id" => meeting.id
        })

      assert :ok = CheckoutSessionExpired.handle(event)

      assert {:ok, %{status: "cancelled"}} = MeetingQueries.get_meeting(meeting.id)
      refute_receive :expired, 100
    end
  end

  describe "handle/1 with an event from another connected account" do
    test "leaves the booking and its meeting untouched" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: nil
        )

      event =
        "evt_FOREIGN_EXPIRED"
        |> expired_event(%{"id" => "cs_FOREIGN", "client_reference_id" => meeting.id})
        |> Map.put("account", "acct_ATTACKER")

      assert :ok = CheckoutSessionExpired.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == "pending"
      assert reloaded.last_event_id == nil
      assert {:ok, %{status: "awaiting_payment"}} = MeetingQueries.get_meeting(meeting.id)
    end
  end

  defp expired_event(event_id, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.expired",
      "created" => System.os_time(:second),
      "data" => %{"object" => object}
    }
  end
end
