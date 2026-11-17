defmodule Tymeslot.BookingSeries.CancelTest do
  @moduledoc """
  "Cancel all remaining": every session of a series still to come is
  cancelled at once, by its booker or its host, with one series
  cancellation email, and the series closed once nothing of it is left.
  Sessions cancelled one at a time close it too, after the last. A paid
  series' refund is in `Tymeslot.BookingSeries.CancelRefundTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.BookingSeriesTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    :ok
  end

  defp series_seats,
    do:
      Repo.all(
        from(p in ParticipantSchema, where: not is_nil(p.series_id), order_by: p.series_position)
      )

  defp jobs(worker, action), do: all_enqueued(worker: worker, args: %{"action" => action})

  defp job_meeting_ids(jobs), do: jobs |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort()

  # The meetings still holding a reminder job.
  defp reminded_ids, do: Enum.uniq(job_meeting_ids(email_jobs("send_reminder_emails")))

  defp statuses_of(seats),
    do: Enum.map(seats, &Repo.get!(MeetingSchema, &1.meeting_id).status)

  describe "a one-to-one series" do
    setup do
      host = host()
      type = series_type(host, reminder_config: [%{"value" => 30, "unit" => "minutes"}])
      assert {:ok, %{series: series}} = book(host, type, 4)

      # Each session has a video room to clean up.
      Enum.each(meetings(), fn meeting ->
        meeting |> Changeset.change(video_room_id: "room-#{meeting.id}") |> Repo.update!()
      end)

      %{host: host, series: series}
    end

    test "cancel all remaining cancels future sessions only", %{series: series} do
      [past | future] = meetings()
      into_the_past!(past)
      future_ids = future |> Enum.map(& &1.id) |> Enum.sort()
      assert reminded_ids() -- [past.id] == future_ids

      assert {:ok, %{cancelled: cancelled, refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert cancelled |> Enum.map(& &1.id) |> Enum.sort() == future_ids
      assert statuses() == [:confirmed, :cancelled, :cancelled, :cancelled]

      assert email_jobs("send_cancellation_emails") == []

      assert [%{args: %{"cancelled_by" => "attendee"} = args}] =
               email_jobs("send_series_cancellation")

      assert Enum.sort(args["occurrence_ids"]) == future_ids

      assert job_meeting_ids(jobs(CalendarEventWorker, "delete")) == future_ids
      assert job_meeting_ids(jobs(VideoSyncWorker, "delete")) == future_ids
      assert reminded_ids() -- [past.id] == []

      # The past session is still there, so is the series' record of it,
      # but nothing of it is left to come.
      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "the host cancels with the host's wording", %{host: host, series: series} do
      assert {:ok, %{cancelled: [_first, _second, _third, _fourth]}} =
               BookingSeries.cancel_remaining(series, caller: :organizer, acting_user: host.user)

      assert [%{args: %{"cancelled_by" => "organizer"}}] = email_jobs("send_series_cancellation")
    end

    test "another host cannot cancel the series", %{series: series} do
      intruder = host("other-host")

      assert {:error, :not_found} = BookingSeries.get_for_organizer(series.id, intruder.user.id)

      assert {:error, :not_found} =
               BookingSeries.cancel_remaining(series,
                 caller: :organizer,
                 acting_user: intruder.user
               )

      assert {:error, :not_found} = BookingSeries.cancel_remaining(series, caller: :organizer)

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
    end

    test "the host finds their own series, the attendee theirs by uid", %{
      host: host,
      series: series
    } do
      assert {:ok, %SeriesSchema{id: id}} =
               BookingSeries.get_for_organizer(series.id, host.user.id)

      assert id == series.id

      assert {:ok, %SeriesSchema{id: ^id}} = BookingSeries.get_for_attendee(series.uid)
      assert {:error, :not_found} = BookingSeries.get_for_attendee("not-a-uid")
      assert {:error, :not_found} = BookingSeries.get_for_attendee(UUID.generate())
      assert {:error, :not_found} = BookingSeries.get_for_organizer("not-an-id", host.user.id)

      assert series |> BookingSeries.occurrences() |> Enum.map(& &1.series_position) ==
               [1, 2, 3, 4]
    end

    test "nothing left to cancel", %{series: series} do
      Enum.each(meetings(), &into_the_past!/1)

      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
      assert is_nil(reload_series(series).cancelled_at)
    end

    test "a second cancel-all is a no-op", %{series: series} do
      assert {:ok, _cancelled} = BookingSeries.cancel_remaining(series, caller: :attendee)

      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert [_one] = email_jobs("send_series_cancellation")
    end

    test "a calendar deletion of the last session closes the series", %{series: series} do
      [first, second, third, fourth] = meetings()

      for meeting <- [first, second, third] do
        assert {:ok, _cancelled} = Meetings.cancel_meeting(meeting)
      end

      assert is_nil(reload_series(series).cancelled_at)

      assert {:ok, _cancelled} = Cancel.execute_external(fourth)
      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "cancelling each session alone closes the series after the last", %{series: series} do
      [first, second, third, fourth] = meetings()

      for meeting <- [first, second, third] do
        assert {:ok, _cancelled} = Meetings.cancel_meeting(meeting)
      end

      assert is_nil(reload_series(series).cancelled_at)

      assert {:ok, _cancelled} = Meetings.cancel_meeting(fourth)

      assert %DateTime{} = reload_series(series).cancelled_at
      # Each was told on its own, and the series sent nothing more.
      assert length(email_jobs("send_cancellation_emails")) == 4
      assert email_jobs("send_series_cancellation") == []
    end
  end

  describe "a group series" do
    setup do
      host = host()
      type = series_type(host, max_participants: 3)
      assert {:ok, %{series: series, meetings: sessions}} = book(host, type, 3)
      %{host: host, series: series, sessions: sessions}
    end

    test "a group series gives up every future seat", %{series: series, sessions: sessions} do
      [first, second, third] = sessions
      other = insert(:participant, meeting: second, email: "alan@example.com")

      assert {:ok, %{cancelled: cancelled, refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      seats = series_seats()
      assert Enum.all?(seats, &(not ParticipantSchema.live?(&1)))

      assert cancelled |> Enum.map(& &1.id) |> Enum.sort() ==
               seats |> Enum.map(& &1.id) |> Enum.sort()

      # Sessions the series was alone in go with it; the shared one stays.
      assert Repo.reload!(first).status == :cancelled
      assert Repo.reload!(third).status == :cancelled
      assert Repo.reload!(second).status == :confirmed
      assert ParticipantSchema.live?(Repo.reload!(other))

      assert email_jobs("send_seat_cancellation_emails") == []
      assert [%{args: args}] = email_jobs("send_series_cancellation")
      assert Enum.sort(args["occurrence_ids"]) == seats |> Enum.map(& &1.id) |> Enum.sort()

      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "an emptied session sends no meeting cancellation of its own", %{series: series} do
      assert {:ok, _cancelled} = BookingSeries.cancel_remaining(series, caller: :attendee)

      assert statuses_of(series_seats()) == [:cancelled, :cancelled, :cancelled]
      assert email_jobs("send_cancellation_emails") == []
      assert email_jobs("send_seat_cancellation_emails") == []
      assert [_one] = email_jobs("send_series_cancellation")
    end

    test "the host cancels a group series", %{host: host, series: series, sessions: sessions} do
      [_first, second, _third] = sessions
      other = insert(:participant, meeting: second, email: "alan@example.com")

      assert {:ok, %{cancelled: [_s1, _s2, _s3], refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :organizer, acting_user: host.user)

      assert Enum.all?(series_seats(), &(not ParticipantSchema.live?(&1)))
      assert Repo.reload!(second).status == :confirmed
      assert ParticipantSchema.live?(Repo.reload!(other))
      assert [%{args: %{"cancelled_by" => "organizer"}}] = email_jobs("send_series_cancellation")
    end

    test "giving up each seat alone closes the series after the last", %{series: series} do
      [first, second, third] = series_seats()

      assert {:ok, _given_up} = Meetings.cancel_seat(first.management_token)
      assert {:ok, _given_up} = Meetings.cancel_seat(second.management_token)
      assert is_nil(reload_series(series).cancelled_at)

      assert {:ok, _given_up} = Meetings.cancel_seat(third.management_token)
      assert %DateTime{} = reload_series(series).cancelled_at
    end
  end

  describe "a series held for approval" do
    test "an open approval request is withdrawn as a whole" do
      host = host()
      type = series_type(host, requires_approval: true, approval_window_hours: 48)
      assert {:ok, %{series: series}} = book(host, type, 3)
      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]

      assert {:ok, %{cancelled: [_first, _second, _third], refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert email_jobs("send_cancellation_emails") == []

      assert [%{args: %{"cancelled_by" => "attendee"}}] =
               email_jobs("send_series_cancellation")

      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert %DateTime{} = reload_series(series).cancelled_at
    end

    test "a declined or expired series request is closed" do
      host = host()
      type = series_type(host, requires_approval: true, approval_window_hours: 48)
      assert {:ok, %{series: declined}} = book(host, type, 2)
      assert {:ok, _released} = SeriesApproval.decline(declined, host.user, nil)
      assert %DateTime{} = reload_series(declined).cancelled_at

      other = series_type(host, requires_approval: true, approval_window_hours: 48, name: "Other")
      assert {:ok, %{series: expired}} = book(host, other, 2)
      assert {:ok, _released} = SeriesApproval.expire(expired)
      assert %DateTime{} = reload_series(expired).cancelled_at
    end
  end
end
