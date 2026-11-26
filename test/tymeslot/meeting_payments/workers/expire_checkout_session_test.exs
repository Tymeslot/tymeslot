defmodule Tymeslot.MeetingPayments.Workers.ExpireCheckoutSessionTest do
  @moduledoc """
  The job that closes the open Stripe Checkout of a booking cancelled while
  it awaited payment, so its attendee cannot pay for it afterwards.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.Workers.ExpireCheckoutSession
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  @account "acct_EXPIRE_HOST"
  @session_id "cs_EXPIRE_ON_CANCEL"
  @expire_path "/v1/checkout/sessions/#{@session_id}/expire"

  setup do
    meeting = insert(:meeting, status: :cancelled, cancelled_at: DateTime.utc_now(:second))

    payment =
      insert(:booking_payment,
        meeting: meeting,
        status: :pending,
        stripe_account_id: @account,
        stripe_checkout_session_id: @session_id
      )

    %{meeting: meeting, payment: payment}
  end

  test "expires the open session on the host's connected account", %{meeting: meeting} do
    StripeStub.expect(
      :expire_checkout_session,
      StripeFixtures.object("checkout_session_expired", %{"id" => @session_id})
    )

    assert :ok = perform_job(ExpireCheckoutSession, %{"meeting_id" => meeting.id})

    assert [%{path: @expire_path, headers: headers}] =
             StripeStub.requests(:expire_checkout_session)

    assert headers["stripe-account"] == @account
  end

  # Stripe expires only an open session. One the attendee completed first
  # is the completion webhook's to settle (it refunds the payment), and one
  # expired already needs nothing more.
  for status <- ["complete", "expired"] do
    test "is done when Stripe finds the session #{status} already", %{meeting: meeting} do
      StripeStub.expect(:expire_checkout_session, not_open_error())
      StripeStub.expect(:retrieve_checkout_session, session(unquote(status)))

      assert :ok = perform_job(ExpireCheckoutSession, %{"meeting_id" => meeting.id})

      assert [%{path: "/v1/checkout/sessions/" <> @session_id, headers: headers}] =
               StripeStub.requests(:retrieve_checkout_session)

      assert headers["stripe-account"] == @account
    end
  end

  test "retries a refusal for a session still open", %{meeting: meeting} do
    StripeStub.expect(:expire_checkout_session, not_open_error())
    StripeStub.expect(:retrieve_checkout_session, session("open"))

    assert {:error, %StripeError{type: "invalid_request_error"}} =
             perform_job(ExpireCheckoutSession, %{"meeting_id" => meeting.id})
  end

  test "retries while Stripe cannot be reached", %{meeting: meeting} do
    StripeStub.expect(:expire_checkout_session, {:error_fixture, "api_error"})
    StripeStub.stub(:retrieve_checkout_session, {:error_fixture, "api_error"})

    assert {:error, %StripeError{type: "api_error"}} =
             perform_job(ExpireCheckoutSession, %{"meeting_id" => meeting.id})
  end

  # No Stripe stub: any request fails the test.
  test "asks Stripe nothing once the payment is no longer pending", %{
    meeting: meeting,
    payment: payment
  } do
    payment |> Changeset.change(status: :failed) |> Repo.update!()

    assert :ok = perform_job(ExpireCheckoutSession, %{"meeting_id" => meeting.id})
  end

  test "is enqueued once per meeting", %{meeting: meeting} do
    assert {:ok, _job} = ExpireCheckoutSession.enqueue(meeting.id)
    assert {:ok, _job} = ExpireCheckoutSession.enqueue(meeting.id)

    assert [_one] = all_enqueued(worker: ExpireCheckoutSession, args: %{meeting_id: meeting.id})
  end

  defp not_open_error do
    StripeFixtures.error_body("invalid_request_error", %{
      "code" => nil,
      "param" => nil,
      "message" =>
        "This Checkout Session is not in an expireable state. Only Checkout Sessions with a status of `open` can be expired."
    })
  end

  defp session(status) do
    StripeFixtures.object("checkout_session_payment", %{"id" => @session_id, "status" => status})
  end
end
