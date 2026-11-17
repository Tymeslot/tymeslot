defmodule Tymeslot.BookingSeries.ApprovedSessionsTest do
  @moduledoc """
  One session of a booked series, on its own: a confirmed session the
  booker moves back into the approval gate is a request of its own,
  approved, declined or moved again without the rest; and one confirmed
  session cancelled, by its booker or its host, is announced for that
  session alone.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :emails
  @moduletag :integration

  import Mox
  import Tymeslot.BookingSeriesTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SeriesAnnouncementWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    :ok
  end

  describe "a confirmed session moved back into the gate" do
    # The series is approved, then the booker moves its second session, which
    # sends that one session back for approval on its own.
    setup do
      %{host: host, series: series} = book_three()
      assert {:ok, _approved} = SeriesApproval.approve(series, host.user)
      [_first, second, _third] = meetings()

      assert {:ok, %{status: :awaiting_approval}} =
               Reschedule.execute(second.uid, move_to(15), host.user.id)

      refute SeriesApproval.series_request?(Repo.reload!(second))
      %{second: Repo.reload!(second)}
    end

    test "is approved on its own, the rest untouched", %{second: second} do
      assert [_request] = email_jobs("send_booking_request_emails")

      assert {:ok, %MeetingSchema{id: id, status: :confirmed}} = Approval.approve(second)
      assert id == second.id
      assert statuses() == [:confirmed, :confirmed, :confirmed]
      assert [_series_confirmation] = all_enqueued(worker: SeriesAnnouncementWorker)
    end

    test "can be moved again while it awaits approval", %{second: second} do
      assert {:ok, %{status: :awaiting_approval}} =
               Reschedule.execute(second.uid, move_to(16), second.organizer_user_id)

      assert %{start_time: start_time} = Repo.reload!(second)
      assert DateTime.to_date(start_time) == 16 |> Paid.at() |> DateTime.to_date()
    end

    test "is declined on its own, the rest still booked", %{second: second} do
      assert {:ok, %MeetingSchema{status: :cancelled}} = Approval.decline(second, "Not that day")

      assert statuses() == [:confirmed, :cancelled, :confirmed]
      assert [%{args: %{"meeting_id" => id}}] = email_jobs("send_booking_request_outcome")
      assert id == second.id
      assert email_jobs("send_series_request_outcome") == []
    end
  end

  describe "cancelling one confirmed session of a series" do
    setup do
      setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
      host = host()

      type = series_type(host)

      insert(:webhook, user: host.user, events: ["meeting.cancelled"])
      assert {:ok, %{meetings: [_first, second, _third]}} = book(host, type, 3)
      %{host: host, second: second}
    end

    test "by the booker is announced for that session", %{second: second} do
      assert {:ok, _cancelled} = Meetings.cancel_meeting(second)
      assert_cancellation_announced(second)
    end

    test "by the host is announced for that session", %{host: host, second: second} do
      assert {:ok, _cancelled} = Meetings.cancel_meeting_with_refund(second, host.user.id, :none)
      assert_cancellation_announced(second)
    end

    defp assert_cancellation_announced(session) do
      assert statuses() == [:confirmed, :cancelled, :confirmed]
      assert [%{args: %{"meeting_id" => id}}] = email_jobs("send_cancellation_emails")
      assert id == session.id
      assert email_jobs("send_series_cancellation") == []

      assert [%{args: %{"event_type" => "meeting.cancelled", "meeting_id" => ^id}}] =
               all_enqueued(worker: WebhookWorker)
    end
  end
end
