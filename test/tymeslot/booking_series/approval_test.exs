defmodule Tymeslot.BookingSeries.ApprovalTest do
  @moduledoc """
  A series on a type requiring approval is one request with one answer:
  every session held with the first session's deadline, one request email
  each way and one expiry job; approving, declining, expiring or
  withdrawing any part of it answers all of it, with one email and, for a
  paid series, one refund of the whole payment. A session answered or
  cancelled on its own, once the series is booked, is in
  `Tymeslot.BookingSeries.ApprovedSessionsTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :emails
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.BookingSeriesTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.BookingSeries.Notifications, as: SeriesNotifications
  alias Tymeslot.CalendarMock

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Meetings.Workers.ApprovalSweepWorker
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.SeriesAnnouncementWorker

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    # The real email service, so the rendered emails reach this process.
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    :ok
  end

  defp drain_emails, do: Oban.drain_queue(queue: :emails, with_recursion: true)

  defp expiry_jobs, do: all_enqueued(worker: ApprovalExpiryWorker)

  defp past_deadline!(seconds_ago \\ 60) do
    past = DateTime.add(DateTime.utc_now(:second), -seconds_ago, :second)

    Repo.update_all(from(m in MeetingSchema, where: not is_nil(m.series_id)),
      set: [approval_deadline_at: past]
    )
  end

  defp sent_emails do
    collect = fn collect, acc ->
      receive do
        {:email, email} -> collect.(collect, [email | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    collect.(collect, [])
  end

  defp to_ada?(email), do: email.to == [{"Ada Lovelace", "ada@example.com"}]

  test "a series request holds every slot and sends one request" do
    %{host: host, type: type} = book_three()

    assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]
    assert meetings() |> Enum.map(& &1.approval_deadline_at) |> Enum.uniq() |> length() == 1

    assert [_request] = email_jobs("send_series_request")
    assert email_jobs("send_booking_request_emails") == []
    assert email_jobs("send_booking_approval_nudge") == []
    assert [%{args: %{"meeting_id" => expiry_for}}] = expiry_jobs()
    assert expiry_for == hd(meetings()).id

    # Every slot is held: the type's own page offers none of them.
    {:ok, occurrences} = BookingSeries.preview(type, Paid.at(7), count: 3)
    assert Enum.all?(occurrences, &match?({:unavailable, _reason}, &1.status))

    assert %{success: 1} = drain_emails()
    assert [_first, _second] = emails = sent_emails()
    {[attendee], [organizer]} = Enum.split_with(emails, &to_ada?/1)

    assert attendee.subject == "Your request for 3 sessions was sent"
    assert organizer.subject == "Ada Lovelace requests 3 sessions"
    assert organizer.to == [{"Grace Hopper", host.user.email}]
    assert organizer.text_body =~ "Approve all sessions:\n"
    assert organizer.text_body =~ "/meeting-request/"
    assert organizer.text_body =~ "Weekly please"
    assert organizer.text_body =~ "Session 3 of 3"
  end

  defp nudge_jobs, do: email_jobs("send_series_request_nudge")

  defp drain_due_emails,
    do: Oban.drain_queue(queue: :emails, with_recursion: true, with_scheduled: true)

  test "a series request reminds its host once, halfway to the deadline" do
    %{series: series} = book_three()
    [first | _rest] = meetings()

    assert [%{args: %{"series_id" => series_id}, scheduled_at: scheduled_at}] = nudge_jobs()
    assert series_id == series.id
    assert email_jobs("send_booking_approval_nudge") == []

    halfway =
      DateTime.add(
        first.approval_requested_at,
        div(DateTime.diff(first.approval_deadline_at, first.approval_requested_at), 2)
      )

    assert abs(DateTime.diff(scheduled_at, halfway)) <= 1

    # Scheduled again, the series still has its one reminder.
    assert {:ok, :scheduled} = SeriesNotifications.schedule_series_request(series)

    assert [_one] = nudge_jobs()

    drain_due_emails()
    reminders = Enum.filter(sent_emails(), &(&1.subject =~ "Reminder: Ada"))

    assert [%{subject: "Reminder: Ada Lovelace requests 3 sessions"} = reminder] = reminders
    refute to_ada?(reminder)
    assert reminder.text_body =~ "Session 3 of 3"
    assert reminder.text_body =~ "/meeting-request/"
  end

  test "a series request answered before its reminder sends none" do
    %{host: host, series: series} = book_three()
    assert {:ok, _sessions} = SeriesApproval.approve(series, host.user)
    assert [_still_queued] = nudge_jobs()

    drain_due_emails()

    assert Enum.filter(sent_emails(), &(&1.subject =~ "Reminder: Ada")) == []
  end

  test "a series request withdrawn before its reminder sends none" do
    %{series: series} = book_three()
    assert {:ok, _released} = SeriesApproval.withdraw(series, :attendee)
    assert [_still_queued] = nudge_jobs()

    drain_due_emails()

    assert statuses() == [:cancelled, :cancelled, :cancelled]
    assert Enum.filter(sent_emails(), &(&1.subject =~ "Reminder: Ada")) == []
  end

  test "a series request expired before its reminder sends none" do
    %{series: series} = book_three()
    past_deadline!()
    assert {:ok, _released} = SeriesApproval.expire(series)
    assert [_still_queued] = nudge_jobs()

    drain_due_emails()

    assert statuses() == [:expired, :expired, :expired]
    assert Enum.filter(sent_emails(), &(&1.subject =~ "Reminder: Ada")) == []
  end

  test "the deadline comes from the first session" do
    host = host()
    # A window longer than the gap to the first session: each session's own
    # cap would give the later ones later deadlines.
    %{} = book_three(host, approval_type(host, approval_window_hours: 336))

    assert [first | _rest] = meetings()
    assert DateTime.compare(first.approval_deadline_at, Paid.at(7)) == :eq
    assert Enum.all?(meetings(), &(&1.approval_deadline_at == first.approval_deadline_at))
    assert Enum.all?(meetings(), &(&1.approval_requested_at == first.approval_requested_at))
  end

  test "approving confirms every session and sends one confirmation" do
    %{host: host, series: series} = book_three()

    assert {:ok, approved} = SeriesApproval.approve(series, host.user)
    assert Enum.map(approved, & &1.id) == Enum.map(meetings(), & &1.id)
    assert statuses() == [:confirmed, :confirmed, :confirmed]
    assert Enum.all?(meetings(), &match?(%DateTime{}, &1.approval_resolved_at))

    assert expiry_jobs() == []
    assert [_announcement] = all_enqueued(worker: SeriesAnnouncementWorker)
    assert email_jobs("send_confirmation_emails") == []

    updates = all_enqueued(worker: CalendarEventWorker, args: %{"action" => "update"})

    assert updates |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort() ==
             meetings() |> Enum.map(& &1.id) |> Enum.sort()

    # Answered once: a second approval finds nothing held.
    assert {:error, :not_awaiting_approval} = SeriesApproval.approve(series, host.user)

    assert :ok = perform_job(SeriesAnnouncementWorker, %{"series_id" => series.id})
    drain_emails()
    subjects = sent_emails() |> Enum.map(& &1.subject) |> Enum.sort()

    assert "Ada Lovelace booked 3 sessions" in subjects
    assert "Your 3 sessions with Grace Hopper are booked" in subjects
    refute Enum.any?(subjects, &(&1 =~ "Appointment"))
  end

  test "only the series' organiser may answer it" do
    %{series: series} = book_three()

    assert {:error, :not_found} = SeriesApproval.approve(series, insert(:user))
    assert {:error, :not_found} = SeriesApproval.decline(series, insert(:user), nil)
    assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]
  end

  test "approving one member approves the series" do
    book_three()
    [_first, second, _third] = meetings()

    assert {:ok, %MeetingSchema{id: id, status: :confirmed}} = Approval.approve(second)
    assert id == second.id
    assert statuses() == [:confirmed, :confirmed, :confirmed]
    assert [_announcement] = all_enqueued(worker: SeriesAnnouncementWorker)
  end

  test "approving after the deadline is refused" do
    %{host: host, series: series} = book_three()
    past_deadline!()

    assert {:error, :past_deadline} = SeriesApproval.approve(series, host.user)
    assert statuses() == [:expired, :expired, :expired]
    refute_enqueued(worker: SeriesAnnouncementWorker)
    assert [%{args: %{"variant" => "expired"}}] = email_jobs("send_series_request_outcome")

    # Through a session, as a single request reports it.
    assert {:error, :not_awaiting_approval} = Approval.approve(hd(meetings()))
  end

  test "declining releases every session and tells the booker once" do
    %{host: host, series: series} = book_three()

    assert {:ok, _declined} = SeriesApproval.decline(series, host.user, "  Fully booked  ")
    assert statuses() == [:cancelled, :cancelled, :cancelled]
    assert Enum.all?(meetings(), &Approval.declined?/1)
    assert Enum.all?(meetings(), &(&1.decline_reason == "Fully booked"))
    assert expiry_jobs() == []

    deletes = all_enqueued(worker: CalendarEventWorker, args: %{"action" => "delete"})
    assert length(deletes) == 3

    assert email_jobs("send_booking_request_outcome") == []

    # A decline is owed however late it goes out.
    assert [%{args: %{"variant" => "declined", "relevant_until" => nil}}] =
             email_jobs("send_series_request_outcome")

    drain_emails()
    assert [declined] = sent_emails()
    assert to_ada?(declined)
    assert declined.subject == "Your request for 3 sessions was declined"
    assert declined.text_body =~ "Fully booked"
    assert declined.text_body =~ "Session 2 of 3"
  end

  test "declining one member through the dashboard declines the series" do
    book_three()

    assert {:ok, %MeetingSchema{status: :cancelled}} =
             Approval.decline(List.last(meetings()), nil)

    assert statuses() == [:cancelled, :cancelled, :cancelled]
    assert [_outcome] = email_jobs("send_series_request_outcome")
  end

  test "expiry releases the series" do
    book_three()
    [first | _rest] = meetings()
    past_deadline!()

    assert :ok = perform_job(ApprovalExpiryWorker, %{"meeting_id" => first.id})
    assert statuses() == [:expired, :expired, :expired]

    # Dropped unsent once the last session has started: three weekly
    # sessions end later than a week past a deadline that just passed.
    assert [%{args: %{"variant" => "expired", "relevant_until" => until}}] =
             email_jobs("send_series_request_outcome")

    assert until == DateTime.to_iso8601(List.last(meetings()).start_time)

    drain_emails()
    assert [expired] = sent_emails()
    assert to_ada?(expired)
    assert expired.subject == "Your request for 3 sessions expired"
  end

  test "a withdrawal the host answered first cancels nothing" do
    %{host: host, series: series} = book_three()
    assert {:ok, _approved} = SeriesApproval.approve(series, host.user)

    assert {:error, :not_awaiting_approval} =
             BookingSeries.cancel_remaining(series, caller: :attendee, expect: :withdraw)

    assert statuses() == [:confirmed, :confirmed, :confirmed]
    assert email_jobs("send_series_cancellation") == []

    # A plain cancel-all of the answered request still cancels it.
    assert {:ok, %{cancelled: [_first, _second, _third]}} =
             BookingSeries.cancel_remaining(series, caller: :attendee)

    assert statuses() == [:cancelled, :cancelled, :cancelled]
  end

  test "withdrawing from the attendee side releases the series" do
    %{series: series} = book_three()
    [_first, second, _third] = meetings()

    assert {:ok, %MeetingSchema{id: id, status: :cancelled}} = Meetings.cancel_meeting(second)
    assert id == second.id
    assert statuses() == [:cancelled, :cancelled, :cancelled]
    refute Enum.any?(meetings(), &Approval.declined?/1)
    assert expiry_jobs() == []

    assert email_jobs("send_cancellation_emails") == []

    assert [%{args: %{"cancelled_by" => "attendee", "series_id" => series_id} = args}] =
             email_jobs("send_series_cancellation")

    assert series_id == series.id
    assert Enum.sort(args["occurrence_ids"]) == meetings() |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "an external calendar delete of one member withdraws the whole series" do
    book_three()
    [first, _second, _third] = meetings()

    assert {:ok, _withdrawn} = Cancel.execute_external(first)

    assert statuses() == [:cancelled, :cancelled, :cancelled]

    assert Enum.all?(
             meetings(),
             &(&1.cancellation_reason == "Cancelled externally via calendar sync")
           )

    assert email_jobs("send_cancellation_emails") == []
    assert [%{args: %{"cancelled_by" => "organizer"}}] = email_jobs("send_series_cancellation")
  end

  describe "a paid approval series" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      # The completed webhook backfills the charge the refund is made on.
      Paid.stub_charge_backfill()

      host = Paid.paid_host()

      type =
        host
        |> Paid.paid_series_type()
        |> Changeset.change(requires_approval: true)
        |> Repo.update!()

      Paid.expect_checkout()
      assert {:ok, :payment_required, %{series: series}} = Paid.book(host, type, 3)

      %{host: host, series: series}
    end

    defp pay(series) do
      event = Paid.completed_event("evt_PAID", series.id, 3 * Paid.price_cents())
      assert :ok = CheckoutSessionCompleted.handle(event)
    end

    test "a paid approval series asks for approval only after payment", %{series: series} do
      assert statuses() == [:awaiting_payment, :awaiting_payment, :awaiting_payment]
      assert email_jobs("send_series_request") == []
      assert expiry_jobs() == []

      pay(series)

      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]
      [first | _rest] = meetings()
      assert DateTime.compare(first.approval_deadline_at, DateTime.utc_now()) == :gt
      assert Enum.all?(meetings(), &(&1.approval_deadline_at == first.approval_deadline_at))

      assert [_request] = email_jobs("send_series_request")
      assert [_expiry] = expiry_jobs()
      refute_enqueued(worker: SeriesAnnouncementWorker)
      assert email_jobs("send_booking_request_emails") == []
    end

    test "declining releases every session and refunds a paid series once", %{
      host: host,
      series: series
    } do
      pay(series)
      payment = BookingPayments.payment_for_series(series.id)

      StripeStub.expect(:create_refund, 1, fn request ->
        assert request.form["charge"] == "ch_SERIES"
        assert request.form["amount"] == to_string(3 * Paid.price_cents())
        StripeStubResponses.refund(request, "re_SERIES")
      end)

      assert {:ok, _declined} = SeriesApproval.decline(series, host.user, nil)
      assert %{success: 1} = drain_refunds()

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      reloaded = BookingPayments.payment_for_series(series.id)
      assert reloaded.id == payment.id
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 3 * Paid.price_cents()
    end

    test "a withdrawal refunds a paid series once", %{series: series} do
      pay(series)
      expect_one_full_refund()

      assert {:ok, _withdrawn} = Meetings.cancel_meeting(List.last(meetings()))
      assert %{success: 1} = drain_refunds()

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert BookingPayments.payment_for_series(series.id).status == :refunded
    end

    test "an expiry refunds a paid series once", %{series: series} do
      pay(series)
      expect_one_full_refund()
      past_deadline!()

      assert :ok = perform_job(ApprovalExpiryWorker, %{"meeting_id" => hd(meetings()).id})
      assert %{success: 1} = drain_refunds()

      assert statuses() == [:expired, :expired, :expired]
      assert BookingPayments.payment_for_series(series.id).status == :refunded
    end

    test "the host cannot cancel a held session on its own", %{host: host, series: series} do
      pay(series)
      [_first, second, _third] = meetings()

      assert {:error, {:not_cancellable, :held_for_series_approval}} =
               Meetings.cancel_meeting_with_refund(second, host.user.id, {:refund, 5_000})

      assert {:error, {:not_cancellable, :held_for_series_approval}} =
               Meetings.cancel_meeting_with_refund(second, host.user.id, :none)

      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]
    end

    test "a paid session moved back into the gate is cancelled on its own with its share refunded",
         %{host: host, series: series} do
      pay(series)
      assert {:ok, _approved} = SeriesApproval.approve(series, host.user)
      [_first, second, _third] = meetings()

      assert {:ok, %{status: :awaiting_approval}} =
               Reschedule.execute(second.uid, move_to(15), host.user.id)

      StripeStub.expect(:create_refund, 1, fn request ->
        assert request.form["amount"] == to_string(Paid.price_cents())
        StripeStubResponses.refund(request, "re_SESSION")
      end)

      assert {:ok, %MeetingSchema{status: :cancelled}} =
               Meetings.cancel_meeting_with_refund(
                 Repo.reload!(second),
                 host.user.id,
                 {:refund, Paid.price_cents()}
               )

      assert statuses() == [:confirmed, :cancelled, :confirmed]

      assert %{status: :partially_refunded, refunded_amount_cents: refunded} =
               BookingPayments.payment_for_series(series.id)

      assert refunded == Paid.price_cents()
    end

    defp expect_one_full_refund do
      StripeStub.expect(:create_refund, 1, fn request ->
        assert request.form["amount"] == to_string(3 * Paid.price_cents())
        StripeStubResponses.refund(request, "re_SERIES")
      end)
    end
  end

  test "the sweep releases a series once, counting its other sessions as answered" do
    book_three()
    past_deadline!()

    assert {:ok, %{expired: 1, skipped: 2, failed: 0}} = perform_job(ApprovalSweepWorker, %{})
    assert statuses() == [:expired, :expired, :expired]
    assert [_outcome] = email_jobs("send_series_request_outcome")
    assert email_jobs("send_booking_request_outcome") == []
  end

  test "a sweep that reaches a series long after its deadline dates every session to it" do
    book_three()
    past_deadline!(30 * 86_400)

    assert {:ok, %{expired: 1}} = perform_job(ApprovalSweepWorker, %{})

    for session <- meetings() do
      assert session.status == :expired
      assert DateTime.compare(session.cancelled_at, session.approval_deadline_at) == :eq
      assert DateTime.compare(session.approval_resolved_at, session.approval_deadline_at) == :eq
    end
  end

  test "a held session cannot be moved on its own" do
    %{host: host} = book_three()
    [_first, second, _third] = meetings()

    assert {:error, {:not_reschedulable, :held_for_series_approval}} =
             Reschedule.execute(second.uid, move_to(8), host.user.id)

    assert Enum.map(meetings(), & &1.start_time) == [Paid.at(7), Paid.at(14), Paid.at(21)]
  end

  # A released request's refund job is due at once.
  defp drain_refunds, do: Oban.drain_queue(queue: :payments, with_scheduled: true)
end
