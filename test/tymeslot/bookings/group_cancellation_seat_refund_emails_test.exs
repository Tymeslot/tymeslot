defmodule Tymeslot.Bookings.GroupCancellationSeatRefundEmailsTest do
  @moduledoc """
  The emails of a group meeting the host cancelled when some seats were
  paid: the organiser's copy says what happens to the money (read from the
  cancellation job's `"seat_refund"` argument), and the participants' copies
  never mention a refund, which the host may yet decline.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Emails.Templates.AppointmentCancellation
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    organizer = insert(:user, locale: "en", name: "Host")
    insert(:profile, user: organizer, timezone: "Europe/London")

    meeting =
      insert(:group_meeting,
        capacity: 6,
        status: :cancelled,
        organizer_user_id: organizer.id,
        organizer_email: "host@example.com",
        organizer_name: "Host",
        attendee_locale: "en",
        meeting_type: "Workshop"
      )

    for {name, cents} <- [{"Ada", 2000}, {"Grace", 6000}] do
      participant = insert(:participant, meeting: meeting, name: name, locale: "en")

      insert(:paid_booking_payment,
        meeting: meeting,
        participant: participant,
        seat_payment: true,
        amount_cents: cents,
        host_user_id: organizer.id,
        stripe_charge_id: nil
      )
    end

    %{meeting: meeting}
  end

  defp cancel_job(meeting, extra) do
    Map.merge(%{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}, extra)
  end

  # Runs the cancellation job, returning what the organiser's email was
  # handed and what it renders to.
  defp organiser_copy(meeting, extra \\ %{}) do
    test = self()

    expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, details ->
      send(test, {:organiser, details})
      {:ok, "sent"}
    end)

    assert :ok = perform_job(EmailWorker, cancel_job(meeting, extra))
    assert_received {:organiser, details}

    {details, AppointmentCancellation.render(:organizer, "host@example.com", details)}
  end

  test "a full-refund group cancellation tells the organiser refunds are on their way", ctx do
    {details, email} = organiser_copy(ctx.meeting, %{"seat_refund" => "full"})

    assert %{choice: :full, count: 2} = details.seat_refunds
    assert email.text_body =~ "€80.00 is being refunded to 2 participants."
    assert email.html_body =~ "Refunds on their way"
    refute email.html_body =~ "Refunds outstanding"
  end

  test "a no-refund group cancellation tells the organiser what they still hold", ctx do
    {details, email} = organiser_copy(ctx.meeting, %{"seat_refund" => "none"})

    assert %{choice: :none, count: 2} = details.seat_refunds
    assert email.html_body =~ "Refunds outstanding"
    assert email.text_body =~ "You still hold €80.00 from 2 participants."
    refute email.text_body =~ "is being refunded"
  end

  test "a cancellation job without seat_refund reads as none", ctx do
    {details, email} = organiser_copy(ctx.meeting)

    assert %{choice: :none, count: 2} = details.seat_refunds
    assert email.text_body =~ "You still hold €80.00 from 2 participants."
  end

  test "a group cancellation with no paid seat says nothing about refunds" do
    free = insert(:group_meeting, capacity: 3, status: :cancelled)
    insert(:participant, meeting: free)

    {details, email} = organiser_copy(free, %{"seat_refund" => "full"})

    assert details.seat_refunds == nil
    refute email.text_body =~ "refund"
  end

  test "participants' cancellation emails never mention a refund", ctx do
    for choice <- ["full", "none"] do
      test = self()

      stub(EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, _details ->
        {:ok, "sent"}
      end)

      assert :ok = perform_job(EmailWorker, cancel_job(ctx.meeting, %{"seat_refund" => choice}))

      seat_jobs =
        all_enqueued(worker: EmailWorker, args: %{"action" => "send_seat_meeting_cancellation"})

      assert length(seat_jobs) == 2

      expect(EmailServiceMock, :send_cancellation_email_to_attendee, 2, fn email, details ->
        send(test, {:attendee, email, details})
        {:ok, "sent"}
      end)

      for job <- seat_jobs, do: assert(:ok = perform_job(EmailWorker, job.args))

      for _seat <- 1..2 do
        assert_received {:attendee, email, details}
        rendered = AppointmentCancellation.render(:attendee, email, details)

        assert rendered.text_body =~ "cancelled"
        refute String.downcase(rendered.text_body) =~ "refund"
        refute String.downcase(rendered.html_body) =~ "refund"
      end
    end
  end
end
