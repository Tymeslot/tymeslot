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

  import Mox
  import Tymeslot.GroupCancellationTestHelpers

  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.MeetingPayments.Workers.GroupCancelRefund
  alias Tymeslot.Meetings
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context -> {:error, :none} end)
    :ok
  end

  defp refund_amounts do
    [worker: GroupCancelRefund]
    |> all_enqueued()
    |> Enum.map(& &1.args["amount_cents"])
    |> Enum.sort()
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
  # neither refunded nor counted. Full and none name the same seats and sums.
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

    for {action, choice, refunds} <- [
          {:refund_seats, "full", [1500, 2000]},
          {:none, "none", []}
        ] do
      test "for a #{choice} refund, the seats settled and what they held", ctx do
        assert {:ok, _cancelled} =
                 Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, unquote(action))

        assert refund_amounts() == unquote(refunds)

        assert seat_refund_arg() == %{
                 "choice" => unquote(choice),
                 "count" => 2,
                 "totals" => [%{"currency" => "eur", "amount_cents" => 3500}]
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
end
