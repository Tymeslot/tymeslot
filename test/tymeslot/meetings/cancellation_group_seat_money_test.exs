defmodule Tymeslot.Meetings.CancellationGroupSeatMoneyTest do
  @moduledoc """
  What the organiser is told when the host cancels a paid group session:
  the seats settled, what each held, and the organiser's cancellation
  email for a full refund or none.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.GroupCancellationTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Meetings
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context -> {:error, :none} end)
    :ok
  end

  # The refunds the cancellation set out to make: a disputed seat's refund,
  # held back by the dispute, is recorded failed and counted apart.
  defp refund_amounts(status \\ :pending) do
    Repo.all(
      from(r in RefundSchema,
        where: r.source == :cancellation and r.status == ^status,
        order_by: r.amount_cents,
        select: r.amount_cents
      )
    )
  end

  defp seat_refund_arg do
    assert [%{args: args}] =
             all_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})

    args["seat_refund"]
  end

  # Drains the enqueued cancellation email job, returning the organiser's
  # copy as rendered.
  defp organiser_email do
    test = self()

    expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, details ->
      send(test, {:organiser, details})
      {:ok, "sent"}
    end)

    stub(EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
      {:ok, "sent"}
    end)

    assert %{failure: 0, discard: 0} = Oban.drain_queue(queue: :emails)
    assert_received {:organiser, details}

    AppointmentCancellation.render(:organizer, "host@example.com", details)
  end

  # The organiser is told of the very seats the cancellation settled, at what
  # each still held then: a seat partly refunded before the cancel counts at
  # its balance, and a disputed seat (its money with the card network) is
  # neither refunded nor counted, a full refund only recording its refund
  # held back for the dispute's close. Full and none name the same seats and
  # sums.
  describe "what the organiser's cancellation email is told" do
    setup do
      ctx = host_and_session()
      paid_seat(ctx, "ada@example.com")

      paid_seat(ctx, "alan@example.com",
        status: :partially_refunded,
        refunded_amount_cents: 500
      )

      paid_seat(ctx, "eve@example.com", status: :disputed)
      ctx
    end

    for {action, choice, refunds, held} <- [
          {:refund_seats, "full", [1500, 2000], [2000]},
          {:none, "none", [], []}
        ] do
      test "for a #{choice} refund, the seats settled and what they held", ctx do
        assert {:ok, _cancelled} =
                 Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, unquote(action))

        assert refund_amounts() == unquote(refunds)
        assert refund_amounts(:failed) == unquote(held)

        assert seat_refund_arg() == %{
                 "choice" => unquote(choice),
                 "count" => 2,
                 "totals" => [%{"currency" => "eur", "amount_cents" => 3500}],
                 "outside_window" => %{"count" => 0, "totals" => []}
               }
      end
    end

    test "a full refund renders the seats being refunded in the organiser's email", ctx do
      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

      email = organiser_email()

      assert email.text_body =~ "REFUNDS ON THEIR WAY:"
      assert email.text_body =~ "€35.00 is being refunded to 2 participants."
      assert email.html_body =~ "Refunds on their way"
    end

    test "no refund renders what the organiser still holds in their email", ctx do
      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

      email = organiser_email()

      assert email.text_body =~ "REFUNDS OUTSTANDING:"
      assert email.text_body =~ "You still hold €35.00 from 2 participants."
      refute email.text_body =~ "is being refunded"
    end
  end

  # A seat paid more than 60 days ago is past the refund window: the host's
  # cancellation queues no refund for it, which would only be refused, and
  # tells the organiser to refund it from Stripe.
  describe "a seat paid outside the refund window" do
    setup do
      ctx = host_and_session()
      paid_seat(ctx, "ada@example.com")

      paid_seat(ctx, "old@example.com",
        paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day),
        amount_cents: 3000
      )

      ctx
    end

    test "is not refunded, and is carried apart to the organiser's email", ctx do
      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

      assert refund_amounts() == [2000]

      assert seat_refund_arg() == %{
               "choice" => "full",
               "count" => 1,
               "totals" => [%{"currency" => "eur", "amount_cents" => 2000}],
               "outside_window" => %{
                 "count" => 1,
                 "totals" => [%{"currency" => "eur", "amount_cents" => 3000}]
               }
             }

      email = organiser_email()

      assert email.text_body =~ "€20.00 is being refunded to 1 participant."

      assert email.text_body =~
               "€30.00 from 1 participant can't be refunded automatically: the payment is older than the 60-day refund window. Refund it from your Stripe dashboard."

      assert email.html_body =~ "Refund it from your Stripe dashboard."
    end

    test "with no seat left to refund, the email says only what Stripe must refund", ctx do
      BookingPaymentSchema
      |> Repo.get_by!(attendee_email: "ada@example.com")
      |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -70, :day))
      |> Repo.update!()

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

      assert refund_amounts() == []

      email = organiser_email()

      assert email.text_body =~ "REFUNDS OUTSTANDING:"
      assert email.text_body =~ "€50.00 from 2 participants can't be refunded automatically"
      refute email.text_body =~ "is being refunded"
    end
  end
end
