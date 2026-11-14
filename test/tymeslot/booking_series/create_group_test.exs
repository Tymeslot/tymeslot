defmodule Tymeslot.BookingSeries.CreateGroupTest do
  @moduledoc """
  Booking a group series: one seat in each of its sessions, each session
  found or created as a single seat booking finds or creates it, all in one
  transaction, with the series' own confirmation in place of every seat's.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.RescheduleSeat
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    host = create_always_bookable_profile(timezone: "Etc/UTC")
    %{host: host, today: Date.utc_today()}
  end

  defmodule NoGroupsChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  defp group_type(host, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          duration_minutes: 30,
          max_participants: 3,
          reminder_config: [%{"value" => 30, "unit" => "minutes"}],
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 12
        ],
        attrs
      )
    )
  end

  # 10:00 UTC, `days` from `today`.
  defp at(today, days), do: today |> Date.add(days) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

  defp weekly(today, count), do: %{mode: :recurring, first_start: at(today, 7), count: count}

  defp form_data(extra \\ %{}),
    do:
      Map.merge(%{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}, extra)

  defp book_series(host, type, series, params \\ %{}, form \\ form_data(), opts \\ []) do
    %{
      duration: 30,
      user_timezone: "Etc/UTC",
      organizer_user_id: host.user.id,
      meeting_type_id: type.id,
      series: series
    }
    |> Map.merge(params)
    |> BookingSeries.book(form, opts)
  end

  # A live session of `type` at `start`, its seats held by `emails`.
  defp session!(host, type, start, emails, attrs \\ []) do
    meeting =
      insert(
        :group_meeting,
        Keyword.merge(
          [
            organizer_user_id: host.user.id,
            meeting_type_id: type.id,
            start_time: start,
            end_time: DateTime.add(start, 30, :minute),
            capacity: type.max_participants,
            status: :confirmed
          ],
          attrs
        )
      )

    for email <- emails, do: insert(:participant, meeting: meeting, email: email)
    meeting
  end

  defp meetings_at(start),
    do: Repo.all(from(m in MeetingSchema, where: m.start_time == ^start))

  defp participant_count, do: Repo.aggregate(ParticipantSchema, :count)
  defp series_count, do: Repo.aggregate(SeriesSchema, :count)

  defp series_seats do
    Repo.all(
      from(p in ParticipantSchema,
        where: not is_nil(p.series_id),
        order_by: p.series_position
      )
    )
  end

  defp jobs(worker, action), do: all_enqueued(worker: worker, args: %{"action" => action})

  test "a weekly group series takes a seat in each session", %{host: host, today: today} do
    type = group_type(host)

    assert {:ok, %{series: series, meetings: meetings, participants: participants}} =
             book_series(host, type, weekly(today, 3))

    assert Enum.map(meetings, & &1.start_time) == Enum.map([7, 14, 21], &at(today, &1))
    assert Enum.all?(meetings, &(&1.capacity == 3 and is_nil(&1.series_id)))
    assert Enum.map(participants, & &1.meeting_id) == Enum.map(meetings, & &1.id)

    stored = series_seats()
    assert Enum.map(stored, & &1.series_position) == [1, 2, 3]
    assert Enum.all?(stored, &(&1.series_id == series.id and &1.email == "ada@example.com"))
    assert Enum.map(stored, & &1.id) == Enum.map(participants, & &1.id)
    assert Repo.aggregate(MeetingSchema, :count) == 3

    assert jobs(CalendarEventWorker, "create") |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort() ==
             meetings |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "joins existing sessions where they exist", %{host: host, today: today} do
    type = group_type(host)
    existing = session!(host, type, at(today, 14), ["bob@example.com"])

    assert {:ok,
            %{meetings: [_first, second, _third], participants: [_first_seat, seat, _third_seat]}} =
             book_series(host, type, weekly(today, 3))

    assert second.id == existing.id
    assert seat.meeting_id == existing.id
    assert [%MeetingSchema{id: id}] = meetings_at(at(today, 14))
    assert id == existing.id

    assert Repo.aggregate(
             from(p in ParticipantSchema, where: p.meeting_id == ^existing.id),
             :count
           ) == 2

    assert [%{args: %{"meeting_id" => ^id}}] = jobs(CalendarEventWorker, "update")
  end

  test "a full session refuses the whole series", %{host: host, today: today} do
    type = group_type(host, max_participants: 2)
    session!(host, type, at(today, 14), ["bob@example.com", "cy@example.com"])

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2, status: status}]}} =
             book_series(host, type, weekly(today, 3))

    assert status == {:unavailable, :session_full}
    assert participant_count() == 2
    assert series_count() == 0
    assert meetings_at(at(today, 7)) == []
    assert meetings_at(at(today, 21)) == []
  end

  test "a session filled inside the lock refuses the whole series", %{host: host, today: today} do
    type = group_type(host, max_participants: 2)
    session = session!(host, type, at(today, 14), ["bob@example.com"])

    on_series_insert(fn -> insert(:participant, meeting: session, email: "cy@example.com") end)

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2, status: status}]}} =
             book_series(host, type, weekly(today, 3))

    assert status == {:unavailable, :session_full}
    assert series_count() == 0
    assert participant_count() == 1
    assert meetings_at(at(today, 7)) == []
    assert jobs(EmailWorker, "send_reminder_emails") == []
  end

  test "a fixed-date type books planned sessions only", %{host: host, today: today} do
    type = group_type(host, fixed_dates: true, series_mode: :flexible)

    planned =
      for days <- [7, 14, 21], do: session!(host, type, at(today, days), [], planned: true)

    assert {:ok, %{meetings: meetings}} =
             book_series(host, type, %{
               mode: :flexible,
               starts: Enum.map([7, 14, 21], &at(today, &1))
             })

    assert Enum.map(meetings, & &1.id) == Enum.map(planned, & &1.id)
    assert length(series_seats()) == 3

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2, status: status}]}} =
             book_series(
               host,
               type,
               %{mode: :flexible, starts: [at(today, 7), at(today, 28)]},
               %{},
               form_data(%{"email" => "eve@example.com"})
             )

    assert status == {:unavailable, :no_session}
    assert meetings_at(at(today, 28)) == []
  end

  describe "the booker cannot hold two seats in one session" do
    test "a seat found before the transaction", %{host: host, today: today} do
      type = group_type(host)
      session!(host, type, at(today, 14), ["ada@example.com"])

      assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2, status: status}]}} =
               book_series(host, type, weekly(today, 3))

      assert status == {:unavailable, :already_booked}
      assert series_count() == 0
      assert participant_count() == 1
    end

    # The unique index catches it; Postgres has aborted the transaction by
    # then, so the refusal is read off the insert's own changeset.
    test "a seat taken inside the lock", %{host: host, today: today} do
      type = group_type(host)
      session = session!(host, type, at(today, 14), ["bob@example.com"])

      on_series_insert(fn -> insert(:participant, meeting: session, email: "ada@example.com") end)

      assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2, status: status}]}} =
               book_series(host, type, weekly(today, 3))

      assert status == {:unavailable, :already_booked}
      assert series_count() == 0
      assert participant_count() == 1
      assert meetings_at(at(today, 7)) == []
    end
  end

  test "paused group bookings refuse the series", %{host: host, today: today} do
    type = group_type(host)
    setup_config(:tymeslot, feature_access_checker: NoGroupsChecker)

    assert {:error, :meeting_type_inactive} = book_series(host, type, weekly(today, 3))
    assert series_count() == 0
    assert Repo.aggregate(MeetingSchema, :count) == 0
  end

  test "no seat confirmation emails, reminders as usual", %{host: host, today: today} do
    type = group_type(host)
    existing = session!(host, type, at(today, 14), ["bob@example.com"])

    assert {:ok, %{meetings: [first, second, third]}} = book_series(host, type, weekly(today, 3))

    assert jobs(EmailWorker, "send_seat_confirmation_emails") == []

    # The sessions the series created are reminded; the one it joined was
    # reminded when its first seat created it, as for a single join.
    reminded = Enum.map(jobs(EmailWorker, "send_reminder_emails"), & &1.args["meeting_id"])
    assert Enum.sort(reminded) == Enum.sort([first.id, third.id])
    assert second.id == existing.id

    # A room job releasing the joined session's held confirmations leaves
    # the series seat to the series' own confirmation.
    assert :ok = Events.announce_video_room_outcome(Repo.reload!(existing))
    [bob] = Repo.all(from(p in ParticipantSchema, where: is_nil(p.series_id)))

    assert [%{args: %{"participant_id" => participant_id}}] =
             jobs(EmailWorker, "send_seat_confirmation_emails")

    assert participant_id == bob.id
  end

  test "a group series refuses guests", %{host: host, today: today} do
    type = group_type(host, max_participants: 3, allow_guests: true)

    assert {:error, :guests_not_allowed_on_series} =
             book_series(host, type, weekly(today, 3), %{guest_emails: ["gus@example.com"]})

    assert series_count() == 0
    assert Repo.aggregate(ParticipantSchema, :count) == 0
  end

  test "a series creating sessions with a video room holds back no seat confirmation", %{
    host: host,
    today: today
  } do
    video = insert(:video_integration, user: host.user, provider: "mirotalk")
    type = group_type(host, allow_video: true, video_integration_id: video.id)

    assert {:ok, %{meetings: meetings}} =
             book_series(host, type, weekly(today, 3), %{}, form_data(), with_video_room: true)

    rooms = all_enqueued(worker: VideoRoomWorker)

    assert rooms |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort() ==
             meetings |> Enum.map(& &1.id) |> Enum.sort()

    assert Enum.all?(rooms, &(&1.args["announce"] == false))

    # The room's release step, run for each session, finds only series seats.
    for meeting <- meetings, do: assert(:ok = Events.announce_video_room_outcome(meeting))
    assert jobs(EmailWorker, "send_seat_confirmation_emails") == []
  end

  test "a later seat moves past the booking window, within the series' year", %{
    host: host,
    today: today
  } do
    host.schedule |> Changeset.change(advance_booking_days: 30) |> Repo.update!()
    type = group_type(host)

    assert {:ok, %{participants: seats}} = book_series(host, type, weekly(today, 8))

    assert {:ok, %{participant: moved}} =
             RescheduleSeat.execute(
               List.last(seats).management_token,
               %{
                 date: Date.to_iso8601(Date.add(today, 57)),
                 time: "11:00",
                 duration: "30min",
                 user_timezone: "Etc/UTC"
               },
               host.user.id
             )

    assert %ParticipantSchema{series_position: 8, cancelled_at: nil} = Repo.reload!(moved)
  end

  test "a moved seat is listed once, at its new time, to the attendee and the host", %{
    host: host,
    today: today
  } do
    type = group_type(host)

    assert {:ok, %{series: series, participants: [_first_seat, seat, _third_seat]}} =
             book_series(host, type, weekly(today, 3))

    new_start = DateTime.new!(Date.add(today, 15), ~T[10:00:00], "Etc/UTC")

    assert {:ok, _moved} =
             RescheduleSeat.execute(
               seat.management_token,
               %{
                 date: Date.to_iso8601(Date.add(today, 15)),
                 time: "10:00",
                 duration: "30min",
                 user_timezone: "Etc/UTC"
               },
               host.user.id
             )

    attendee = BookingSeries.attendee_overview(series, host.profile)
    organizer = BookingSeries.organizer_overview(series)

    for overview <- [attendee, organizer] do
      assert Enum.map(overview.sessions, & &1.position) == [1, 2, 3]
      assert Enum.at(overview.sessions, 1).start_time == new_start
    end

    assert attendee.upcoming == 3
  end

  test "a moved seat stays in its series", %{host: host, today: today} do
    type = group_type(host)

    assert {:ok, %{series: series, participants: [_first_seat, seat, _third_seat]}} =
             book_series(host, type, weekly(today, 3))

    assert {:ok, %{meeting: new_session, participant: moved}} =
             RescheduleSeat.execute(
               seat.management_token,
               %{
                 date: Date.to_iso8601(Date.add(today, 15)),
                 time: "10:00",
                 duration: "30min",
                 user_timezone: "Etc/UTC"
               },
               host.user.id
             )

    assert %ParticipantSchema{series_id: series_id, series_position: 2, cancelled_at: nil} =
             Repo.reload!(moved)

    assert series_id == series.id
    assert %ParticipantSchema{cancelled_at: %DateTime{}} = Repo.reload!(seat)

    # The move is announced like any seat's; the room release still leaves
    # the seat to its series.
    assert [%{args: %{"participant_id" => moved_id}}] =
             jobs(EmailWorker, "send_seat_reschedule_emails")

    assert moved_id == moved.id
    assert :ok = Events.announce_video_room_outcome(new_session)
    assert jobs(EmailWorker, "send_seat_confirmation_emails") == []
  end

  # Runs `fun` the moment the series row is inserted: after the series was
  # checked, inside its transaction and under its schedule lock, before any
  # seat is taken.
  defp on_series_insert(fun) do
    handler_id = "series-group-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata[:source] == "booking_series" and
               String.starts_with?(metadata[:query], "INSERT") and
               is_nil(Process.get(:series_hook_ran)) do
            Process.put(:series_hook_ran, true)
            fun.()
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
