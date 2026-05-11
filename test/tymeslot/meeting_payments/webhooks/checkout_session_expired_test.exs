defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpiredTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo

  describe "handle/1" do
    test "marks the booking_payment failed and the meeting expired" do
      meeting = insert(:meeting, status: "awaiting_payment")

      bp =
        insert(:booking_payment,
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
  end

  defp expired_event(event_id, object) do
    %{
      "id" => event_id,
      "type" => "checkout.session.expired",
      "created" => System.os_time(:second),
      "data" => %{"object" => object}
    }
  end
end
