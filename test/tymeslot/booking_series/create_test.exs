defmodule Tymeslot.BookingSeries.CreateTest do
  @moduledoc """
  Booking a one-to-one series through the booking submission: every session
  an ordinary meeting linked to one series row, all or none, each with its
  own reminders and calendar job and no confirmation email of its own.
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
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
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

  defmodule DenyChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :recurring_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  defp series_type(host, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          duration_minutes: 30,
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

  defp params(host, type, series) do
    %{
      duration: 30,
      user_timezone: "Etc/UTC",
      organizer_user_id: host.user.id,
      meeting_type_id: type.id,
      series: series
    }
  end

  defp weekly(today, count), do: %{mode: :recurring, first_start: at(today, 7), count: count}

  defp form_data, do: %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}

  # Through the context, with the booker's form filled in.
  defp book_series(host, type, series) do
    params = params(host, type, series)
    BookingSeries.book(params, form_data())
  end

  defp meeting_count, do: Repo.aggregate(MeetingSchema, :count)
  defp series_count, do: Repo.aggregate(SeriesSchema, :count)

  defp jobs(worker, action), do: all_enqueued(worker: worker, args: %{"action" => action})

  describe "guests" do
    test "a series refuses guests and books nothing", %{host: host, today: today} do
      type = series_type(host, allow_guests: true)
      params = Map.put(params(host, type, weekly(today, 3)), :guest_emails, ["gus@example.com"])

      assert {:error, :guests_not_allowed_on_series} = BookingSeries.book(params, form_data())
      assert meeting_count() == 0
      assert series_count() == 0
    end

    test "a guest list the type ignores refuses nothing", %{host: host, today: today} do
      type = series_type(host, allow_guests: false)
      params = Map.put(params(host, type, weekly(today, 2)), :guest_emails, ["gus@example.com"])

      assert {:ok, %{meetings: [_first, _second]}} = BookingSeries.book(params, form_data())
      assert Repo.aggregate(GuestSchema, :count) == 0
    end

    test "a single booking on the same type still takes guests", %{host: host, today: today} do
      type = series_type(host, allow_guests: true, series_required: false)

      params =
        host
        |> params(type, nil)
        |> Map.delete(:series)
        |> Map.merge(%{
          date: Date.add(today, 7),
          time: "09:00",
          guest_emails: ["gus@example.com"]
        })

      assert {:ok, %MeetingSchema{id: meeting_id}} =
               Orchestrator.submit_booking(%{form_data: form_data(), meeting_params: params},
                 organizer_user_id: host.user.id
               )

      assert [%GuestSchema{email: "gus@example.com"}] =
               Repo.all(from(g in GuestSchema, where: g.meeting_id == ^meeting_id))
    end
  end

  test "books a weekly series as linked meetings", %{host: host, today: today} do
    type = series_type(host)

    assert {:ok, %{series: series, meetings: meetings}} =
             Orchestrator.submit_booking(
               %{form_data: form_data(), meeting_params: params(host, type, weekly(today, 4))},
               organizer_user_id: host.user.id
             )

    assert Enum.map(meetings, & &1.start_time) ==
             Enum.map([7, 14, 21, 28], &at(today, &1))

    stored = Repo.all(from(m in MeetingSchema, order_by: m.series_position))
    assert Enum.map(stored, & &1.series_position) == [1, 2, 3, 4]
    assert Enum.all?(stored, &(&1.series_id == series.id and &1.status == :confirmed))
    assert stored |> Enum.map(& &1.uid) |> Enum.uniq() |> length() == 4

    assert %SeriesSchema{
             mode: :recurring,
             frequency: :weekly,
             interval: 1,
             occurrences_count: 4,
             attendee_email: "ada@example.com",
             organizer_user_id: organizer_user_id
           } = Repo.get!(SeriesSchema, series.id)

    assert organizer_user_id == host.user.id
    assert series_count() == 1

    assert jobs(CalendarEventWorker, "create") |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort() ==
             stored |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "reminders are scheduled for every occurrence, confirmation emails for none", %{
    host: host,
    today: today
  } do
    type = series_type(host)

    assert {:ok, %{meetings: meetings}} = book_series(host, type, weekly(today, 4))

    reminded = Enum.map(jobs(EmailWorker, "send_reminder_emails"), & &1.args["meeting_id"])
    assert Enum.sort(reminded) == meetings |> Enum.map(& &1.id) |> Enum.sort()
    assert jobs(EmailWorker, "send_confirmation_emails") == []

    # Each announcement is claimed, so a later reschedule of one session is
    # announced as a reschedule rather than a new booking.
    assert Enum.all?(Repo.all(MeetingSchema), &match?(%DateTime{}, &1.announced_at))
  end

  test "a flexible series at different times", %{host: host, today: today} do
    type = series_type(host, series_mode: :flexible, series_frequency: nil)
    picks = [at(today, 9), DateTime.add(at(today, 3), 5, :hour), at(today, 5)]

    assert {:ok, %{series: series, meetings: meetings}} =
             book_series(host, type, %{mode: :flexible, starts: picks})

    assert Enum.map(meetings, &{&1.series_position, &1.start_time}) == [
             {1, DateTime.add(at(today, 3), 5, :hour)},
             {2, at(today, 5)},
             {3, at(today, 9)}
           ]

    assert %{mode: :flexible, frequency: nil, occurrences_count: 3} = series
  end

  test "a clash refuses the whole series", %{host: host, today: today} do
    insert(:meeting,
      organizer_user_id: host.user.id,
      start_time: at(today, 21),
      end_time: DateTime.add(at(today, 21), 30, :minute),
      status: :confirmed
    )

    type = series_type(host)

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 3, status: status}]}} =
             book_series(host, type, weekly(today, 4))

    assert status == {:unavailable, :booked}
    assert meeting_count() == 1
    assert series_count() == 0
    assert jobs(CalendarEventWorker, "create") == []
  end

  test "a conflict inside the lock refuses the whole series", %{host: host, today: today} do
    type = series_type(host)
    book_between_check_and_insert(host, at(today, 14))

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2, status: status}]}} =
             book_series(host, type, weekly(today, 4))

    assert status == {:unavailable, :booked}
    assert series_count() == 0
    assert meeting_count() == 0
    assert jobs(EmailWorker, "send_reminder_emails") == []
  end

  test "a booking limit reached inside the lock refuses the whole series", %{today: today} do
    host =
      create_always_bookable_profile(timezone: "Etc/UTC", profile: %{max_bookings_per_week: 1})

    type = series_type(host)
    book_between_check_and_insert(host, DateTime.add(at(today, 14), 2, :hour))

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2, status: status}]}} =
             book_series(host, type, weekly(today, 3))

    assert status == {:unavailable, :limit_reached}
    assert series_count() == 0
  end

  test "a session taken in the meantime comes back through the booking submission", %{
    host: host,
    today: today
  } do
    insert(:meeting,
      organizer_user_id: host.user.id,
      start_time: at(today, 14),
      end_time: DateTime.add(at(today, 14), 30, :minute),
      status: :confirmed
    )

    type = series_type(host)

    assert {:error, {:occurrences_unavailable, [%Occurrence{position: 2}]}} =
             Orchestrator.submit_booking(
               %{form_data: form_data(), meeting_params: params(host, type, weekly(today, 3))},
               organizer_user_id: host.user.id
             )

    assert series_count() == 0
  end

  test "a video type's sessions each get a room, announced with the series", %{
    host: host,
    today: today
  } do
    video = insert(:video_integration, user: host.user, provider: "mirotalk")
    type = series_type(host, allow_video: true, video_integration_id: video.id)

    assert {:ok, %{meetings: meetings}} =
             BookingSeries.book(params(host, type, weekly(today, 3)), form_data(),
               with_video_room: true
             )

    rooms = all_enqueued(worker: VideoRoomWorker)

    assert rooms |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort() ==
             meetings |> Enum.map(& &1.id) |> Enum.sort()

    # The room holds back no announcement: each session is announced with
    # the series, and none sends a confirmation of its own.
    assert Enum.all?(rooms, &(&1.args["announce"] == false))
    assert jobs(EmailWorker, "send_confirmation_emails") == []
    assert Enum.all?(Repo.all(MeetingSchema), &match?(%DateTime{}, &1.announced_at))
  end

  test "rescheduling one session keeps it in the series and announces a reschedule", %{
    host: host,
    today: today
  } do
    type = series_type(host)

    assert {:ok, %{series: series, meetings: [_first, second, _third]}} =
             book_series(host, type, weekly(today, 3))

    new_params = %{
      date: Date.to_iso8601(Date.add(today, 15)),
      time: "11:00",
      duration: 30,
      user_timezone: "Etc/UTC"
    }

    assert {:ok, _moved} = Reschedule.execute(second.uid, new_params, host.user.id)

    moved = Repo.get!(MeetingSchema, second.id)
    assert moved.start_time == DateTime.add(at(today, 15), 1, :hour)
    assert {moved.series_id, moved.series_position} == {series.id, 2}

    assert [_one] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_reschedule_emails", "meeting_id" => second.id}
             )

    assert jobs(EmailWorker, "send_confirmation_emails") == []
  end

  test "the window applies only to the first occurrence", %{host: host, today: today} do
    host.schedule |> Changeset.change(advance_booking_days: 30) |> Repo.update!()
    type = series_type(host)

    assert {:ok, %{meetings: meetings}} = book_series(host, type, weekly(today, 8))
    assert List.last(meetings).start_time == at(today, 7 + 7 * 7)
  end

  describe "moving a later session past the booking window" do
    setup %{host: host, today: today} do
      host.schedule |> Changeset.change(advance_booking_days: 30) |> Repo.update!()
      type = series_type(host)
      {:ok, %{meetings: meetings}} = book_series(host, type, weekly(today, 8))
      # The eighth session, 56 days out.
      %{last: List.last(meetings)}
    end

    test "moves within the series' year", %{host: host, today: today, last: last} do
      assert {:ok, _moved} = Reschedule.execute(last.uid, move_to(today, 57), host.user.id)

      assert Repo.get!(MeetingSchema, last.id).start_time ==
               DateTime.new!(Date.add(today, 57), ~T[11:00:00], "Etc/UTC")
    end

    test "stops a year after the first session", %{host: host, today: today, last: last} do
      # The first session is 7 days out, so its year ends on day 372.
      assert {:error, {:too_far_ahead, _days}} =
               Reschedule.execute(last.uid, move_to(today, 380), host.user.id)
    end

    test "the first session keeps the booking window", %{host: host, today: today} do
      first = first_session(host)

      assert {:error, {:too_far_ahead, 30}} =
               Reschedule.execute(first.uid, move_to(today, 40), host.user.id)
    end

    test "the year stays anchored on the first session as booked", %{
      host: host,
      today: today,
      last: last
    } do
      # The first session moved far out: the second, 14 days out, is now
      # the earliest, but the year still ends on day 372.
      host
      |> first_session()
      |> Changeset.change(
        start_time: at(today, 360),
        end_time: DateTime.add(at(today, 360), 30, :minute)
      )
      |> Repo.update!()

      assert {:error, {:too_far_ahead, _days}} =
               Reschedule.execute(last.uid, move_to(today, 375), host.user.id)
    end

    test "a single booking stays inside the window", %{host: host, today: today} do
      single =
        insert(:meeting,
          organizer_user_id: host.user.id,
          start_time: at(today, 8),
          end_time: DateTime.add(at(today, 8), 30, :minute),
          duration: 30,
          status: "confirmed"
        )

      assert {:error, {:too_far_ahead, 30}} =
               Reschedule.execute(single.uid, move_to(today, 57), host.user.id)
    end
  end

  defp first_session(host) do
    Repo.one!(
      from(m in MeetingSchema,
        where: m.organizer_user_id == ^host.user.id and m.series_position == 1
      )
    )
  end

  defp move_to(today, days),
    do: %{
      date: Date.to_iso8601(Date.add(today, days)),
      time: "11:00",
      duration: 30,
      user_timezone: "Etc/UTC"
    }

  test "a series on a type without access is refused", %{host: host, today: today} do
    setup_config(:tymeslot, feature_access_checker: DenyChecker)
    type = series_type(host)

    assert {:error, :series_not_offered} = book_series(host, type, weekly(today, 4))
    assert series_count() == 0
  end

  describe "a type saved with series and email confirmation before the rule" do
    test "refuses the series", %{host: host, today: today} do
      type = series_type(host, requires_email_verification: true)

      assert {:error, :series_not_offered} = book_series(host, type, weekly(today, 4))
      assert meeting_count() == 0
      assert series_count() == 0
    end

    test "books a single session awaiting confirmation, even when the series is required", %{
      host: host,
      today: today
    } do
      type = series_type(host, requires_email_verification: true, series_required: true)

      assert {:ok, %MeetingSchema{status: :awaiting_verification, series_id: nil}} =
               Create.execute(single(host, type, today), form_data())

      assert series_count() == 0
    end
  end

  test "an approval type books the series held for approval", %{host: host, today: today} do
    held = series_type(host, requires_approval: true)

    assert {:ok, %{meetings: meetings}} = book_series(host, held, weekly(today, 4))

    assert Enum.map(meetings, & &1.status) == List.duplicate(:awaiting_approval, 4)
    assert series_count() == 1
  end

  test "a request in the other mode than the type's is refused", %{host: host, today: today} do
    type = series_type(host)

    assert {:error, :series_not_offered} =
             book_series(host, type, %{mode: :flexible, starts: [at(today, 7), at(today, 8)]})
  end

  test "a session count the type does not offer is refused", %{host: host, today: today} do
    type = series_type(host)

    assert {:error, :invalid_count} = book_series(host, type, weekly(today, 13))
    assert series_count() == 0
  end

  test "a single booking on a required-series type is refused", %{host: host, today: today} do
    type = series_type(host)

    assert {:error, :series_required} = Create.execute(single(host, type, today), form_data())
    assert meeting_count() == 0
  end

  test "a single booking on an optional-series type books one meeting with no series", %{
    host: host,
    today: today
  } do
    type = series_type(host, series_required: false)

    assert {:ok, %MeetingSchema{series_id: nil, series_position: nil}} =
             Create.execute(single(host, type, today), form_data())

    assert series_count() == 0
  end

  test "a calendar timeout refuses the series", %{host: host, today: today} do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:error, :timeout}
    end)

    type = series_type(host)

    # The preview reads an unreachable calendar as free, as a single
    # booking does; booking the series does not.
    assert {:ok, _occurrences} = BookingSeries.preview(type, at(today, 7), count: 4)
    assert {:error, :availability_unverifiable} = book_series(host, type, weekly(today, 4))
    assert meeting_count() == 0
    assert series_count() == 0
  end

  defp single(host, type, today) do
    %{
      date: Date.add(today, 7),
      time: "10:00",
      duration: 30,
      user_timezone: "Etc/UTC",
      organizer_user_id: host.user.id,
      meeting_type_id: type.id
    }
  end

  # Books a meeting for the host at `start`, the moment the series row is
  # inserted: after the series was checked, inside its transaction and under
  # its schedule lock, before any session is inserted.
  defp book_between_check_and_insert(host, start) do
    handler_id = "series-create-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata[:source] == "booking_series" and
               String.starts_with?(metadata[:query], "INSERT") and
               is_nil(Process.get(:conflict_booked)) do
            Process.put(:conflict_booked, true)

            insert(:meeting,
              organizer_user_id: host.user.id,
              start_time: start,
              end_time: DateTime.add(start, 30, :minute),
              status: :confirmed
            )
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
