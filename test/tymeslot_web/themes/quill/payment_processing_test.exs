defmodule TymeslotWeb.Themes.Quill.PaymentProcessingTest do
  @moduledoc """
  Covers the Quill `payment-processing` return page reached after a
  successful Stripe Checkout redirect.

  Locks in:
    * the processing UI when the payment is still pending,
    * the confirmed UI once the webhook has marked the row paid,
    * the awaiting-approval, declined and expired outcomes for a paid
      gated booking (a full pipeline pass through the approval gate must
      never be told it is "confirmed", nor left spinning forever),
    * mount subscribes before it reads state, so a webhook race landing
      mid-mount still self-corrects instead of spinning forever,
    * authorisation: rejecting a session_id that doesn't match the
      stored Checkout Session id (cross-meeting probing),
    * authorisation: rejecting a request whose URL slug doesn't match
      the host's configured booking_theme.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Phoenix.PubSub
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Profiles

  setup do
    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: "1"})

    %{user: user, profile: profile}
  end

  test "renders processing UI when payment still pending", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Confirming your payment"
  end

  test "flips to confirmation UI when broadcast says paid", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    bp =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        status: "pending",
        stripe_checkout_session_id: "cs_TEST"
      )

    {:ok, view, _html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    # Flip the row to paid (simulating the webhook side effect) and broadcast
    {:ok, _bp} =
      BookingPaymentQueries.update(bp, %{
        status: "paid",
        paid_at: DateTime.utc_now(:second)
      })

    PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting.id}", :paid)

    assert render(view) =~ "Booking confirmed"
  end

  test "a webhook race landing mid-mount still self-corrects instead of spinning forever", %{
    conn: conn,
    user: user
  } do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    bp =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        status: "pending",
        stripe_checkout_session_id: "cs_TEST"
      )

    # Fires the moment `authorize/3` issues its last read (the booking_payment
    # lookup) — still inside `mount_payment_processing/3`, before that
    # function returns. Simulates the webhook completing, and broadcasting,
    # in the gap between reading state and subscribing: with the fix,
    # subscribe already happened (it is the first thing mount does), so the
    # broadcast lands in the mailbox and `handle_info(:paid, _)` corrects the
    # assigns once mount finishes. Before the fix, subscribe hadn't happened
    # yet at this point, so the broadcast is simply never delivered.
    handler_id = "quill-payment-processing-mount-race-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source == "booking_payments" do
          :telemetry.detach(handler_id)

          {:ok, _bp} =
            BookingPaymentQueries.update(bp, %{status: "paid", paid_at: DateTime.utc_now(:second)})

          {:ok, _meeting} = MeetingQueries.update_meeting(meeting, %{status: "confirmed"})

          PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting.id}", :paid)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, view, _html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert render(view) =~ "Booking confirmed"
  end

  test "confirmation shows the time in the attendee's timezone", %{conn: conn, user: user} do
    # 14:00 UTC in June is 10:00 in New York (EDT, UTC-4).
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "awaiting_payment",
        start_time: ~U[2026-06-15 14:00:00Z],
        attendee_timezone: "America/New_York"
      )

    bp =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        status: "pending",
        stripe_checkout_session_id: "cs_TEST"
      )

    {:ok, view, _html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    {:ok, _bp} =
      BookingPaymentQueries.update(bp, %{status: "paid", paid_at: DateTime.utc_now(:second)})

    PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting.id}", :paid)

    html = render(view)
    assert html =~ "10:00"
    refute html =~ "14:00"
  end

  test "renders the awaiting-approval request wording, not confirmed, for a paid gated booking",
       %{conn: conn, user: user} do
    deadline = DateTime.add(DateTime.utc_now(:second), 3600, :second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "awaiting_approval",
        approval_deadline_at: deadline
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: "paid",
      paid_at: DateTime.utc_now(:second),
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Payment received"
    refute html =~ "Booking confirmed"
  end

  test "renders the declined wording and mentions the refund for a declined gated booking", %{
    conn: conn,
    user: user
  } do
    now = DateTime.utc_now(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "cancelled",
        approval_resolved_at: now,
        decline_reason: "Can't make this time"
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: "refunded",
      paid_at: now,
      refunded_amount_cents: 5000,
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Booking not accepted"
    assert html =~ "refunded"
    refute html =~ "Booking confirmed"
    refute html =~ "Confirming your payment"
  end

  test "renders the expired wording and mentions the refund for a lapsed gated booking", %{
    conn: conn,
    user: user
  } do
    now = DateTime.utc_now(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "expired",
        approval_resolved_at: now
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: "refunded",
      paid_at: now,
      refunded_amount_cents: 5000,
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Booking request expired"
    assert html =~ "refunded"
    refute html =~ "Booking confirmed"
    refute html =~ "Confirming your payment"
  end

  test "a declined booking still shows the refund message when the refund itself failed and left the payment 'paid'",
       %{conn: conn, user: user} do
    now = DateTime.utc_now(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "cancelled",
        approval_resolved_at: now
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: "paid",
      paid_at: now,
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Booking not accepted"
    refute html =~ "Booking confirmed"
  end

  test "rejects mismatched session_id", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_REAL"
    )

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_FAKE")
  end

  test "rejects mismatched theme slug (host uses Rhythm)", %{conn: conn, user: user} do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{booking_theme: "2"})

    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_TEST"
    )

    assert {:error, {:redirect, _info}} =
             live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")
  end

  test "dead render does not load page data", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_TEST"
    )

    ref = make_ref()
    parent = self()
    handler_id = "quill-payment-processing-dead-render-#{inspect(ref)}"
    data_sources = ~w(meetings booking_payments)

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source in data_sources, do: send(parent, {:db_query, ref, source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    get(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    received_sources =
      Enum.flat_map(1..50, fn _iteration ->
        receive do
          {:db_query, ^ref, source} -> [source]
        after
          0 -> []
        end
      end)

    assert received_sources == [],
           "Data-loading queries fired during dead render: #{inspect(received_sources)}"
  end
end
