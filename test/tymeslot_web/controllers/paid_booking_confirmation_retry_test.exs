defmodule TymeslotWeb.PaidBookingConfirmationRetryTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  @secret "whsec_test_paid_confirmation"
  @account "acct_TEST_HOST"

  setup do
    Application.put_env(:tymeslot, :stripe_connect_webhook_secret, @secret)
    Application.put_env(:swoosh, :shared_test_process, self())
    # The real email service, so the confirmation is delivered through Swoosh.
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    on_exit(fn ->
      Application.delete_env(:tymeslot, :stripe_connect_webhook_secret)
      Application.delete_env(:swoosh, :shared_test_process)
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
    end)

    user = insert(:user)

    meeting =
      insert(:meeting,
        status: "awaiting_payment",
        organizer_user_id: user.id,
        organizer_email: user.email
      )

    payment =
      insert(:booking_payment,
        meeting: meeting,
        status: "pending",
        stripe_account_id: @account,
        stripe_checkout_session_id: "cs_TEST_RETRY"
      )

    payload =
      Jason.encode!(%{
        "id" => "evt_RETRY_#{System.unique_integer([:positive])}",
        "account" => @account,
        "type" => "checkout.session.completed",
        "created" => System.os_time(:second),
        "data" => %{
          "object" => %{
            "id" => "cs_TEST_RETRY",
            "client_reference_id" => meeting.id,
            "payment_status" => "paid",
            "amount_total" => payment.amount_cents,
            "currency" => payment.currency
          }
        }
      })

    %{meeting: meeting, payment: payment, payload: payload}
  end

  # The confirmation emails commit with the payment's transition. When they
  # cannot be queued, the payment and the meeting stay as they were, Stripe is
  # told to redeliver, and the redelivery confirms the booking once, with one
  # confirmation.
  test "a confirmation that cannot be queued is retried by Stripe and sent once", %{
    conn: conn,
    meeting: meeting,
    payment: payment,
    payload: payload
  } do
    # The confirmation's insert reports a failure; every other job inserts.
    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn
      %Ecto.Changeset{changes: %{args: %{"action" => "send_confirmation_emails"}}} ->
        {:error, :queue_not_available}

      changeset ->
        :meck.passthrough([changeset])
    end)

    try do
      assert conn |> post_connect(payload) |> response(503) == ""
    after
      :meck.unload(Oban)
    end

    reloaded_payment = Repo.reload!(payment)
    assert reloaded_payment.status == "pending"
    assert is_nil(reloaded_payment.last_event_id)

    assert {:ok, %{status: "awaiting_payment", announced_at: nil}} =
             MeetingQueries.get_meeting(meeting.id)

    assert all_enqueued(worker: EmailWorker) == []
    assert all_enqueued(worker: CalendarEventWorker) == []

    assert build_conn() |> post_connect(payload) |> response(200) == ""
    # A further redelivery of the same event changes nothing.
    assert build_conn() |> post_connect(payload) |> response(200) == ""

    assert Repo.reload!(payment).status == "paid"
    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)

    assert [_one] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
             )

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :emails)

    assert_received {:email, first}
    assert_received {:email, second}
    refute_received {:email, _third}

    assert Enum.sort(Enum.flat_map([first, second], &recipient_emails/1)) ==
             Enum.sort([meeting.attendee_email, meeting.organizer_email])
  end

  defp recipient_emails(email), do: Enum.map(email.to, fn {_name, address} -> address end)

  defp post_connect(conn, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "stripe-signature",
      PaymentTestHelpers.generate_stripe_signature(payload, @secret)
    )
    |> assign(:raw_body, payload)
    |> post("/webhooks/stripe/connect", payload)
  end
end
