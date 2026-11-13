defmodule Tymeslot.BookingSeries.CreateRaceTest do
  @moduledoc """
  A series and a single booking submitted for the same time at once,
  through the whole booking flow, on real connections staged by
  `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).

  Both pass every check made before the booking transaction, since neither
  booking exists yet. Each contender parks right after inserting its first
  meeting, so the winner holds the organiser's schedule lock while the
  loser waits on it and then finds the winner's meeting.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [create_always_bookable_profile: 1]
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.Create
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    {user, type} =
      unboxed(fn ->
        user = create_always_bookable_profile(timezone: "Etc/UTC").user

        type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            series_mode: :recurring,
            series_frequency: :weekly,
            series_interval: 1,
            series_min_occurrences: 2,
            series_max_occurrences: 6,
            series_required: false
          )

        {user, type}
      end)

    last_job_id = unboxed(fn -> Repo.aggregate(Oban.Job, :max, :id) || 0 end)

    on_exit(fn ->
      unboxed(fn ->
        # The winner commits its follow-up jobs (reminders, calendar sync).
        Repo.delete_all(from(j in Oban.Job, where: j.id > ^last_job_id))
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(s in SeriesSchema, where: s.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, type: type, today: Date.utc_today()}
  end

  test "a single booking and a series racing for one slot: exactly one wins", ctx do
    contested = ctx.today |> Date.add(14) |> DateTime.new!(~T[10:00:00], "Etc/UTC")

    params = %{
      duration: 30,
      user_timezone: "Etc/UTC",
      organizer_user_id: ctx.user.id,
      meeting_type_id: ctx.type.id
    }

    series = %{mode: :recurring, first_start: DateTime.add(contested, -7, :day), count: 3}
    single = %{date: DateTime.to_date(contested), time: "10:00"}

    [single_result, series_result] =
      race([
        fn hold ->
          park_after_insert(hold, fn -> Create.execute(Map.merge(params, single), form()) end)
        end,
        fn hold ->
          park_after_insert(hold, fn ->
            BookingSeries.book(Map.put(params, :series, series), form())
          end)
        end
      ])

    {meetings, series_rows} =
      unboxed(fn ->
        {Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^ctx.user.id)),
         Repo.aggregate(
           from(s in SeriesSchema, where: s.organizer_user_id == ^ctx.user.id),
           :count
         )}
      end)

    case {single_result, series_result} do
      {{:ok, %MeetingSchema{}}, {:error, {:occurrences_unavailable, unavailable}}} ->
        assert [%Occurrence{position: 2, status: {:unavailable, :booked}}] = unavailable
        assert [%{series_id: nil, start_time: ^contested}] = meetings
        assert series_rows == 0

      {{:error, :slot_taken}, {:ok, %{meetings: booked}}} ->
        assert length(booked) == 3
        assert length(meetings) == 3
        assert Enum.all?(meetings, &(&1.series_id != nil))
        assert series_rows == 1

      other ->
        flunk("expected exactly one winner, got #{inspect(other)}")
    end
  end

  defp park_after_insert(hold, fun) do
    RaceConductor.arm(hold, RaceConductor.insert_into("meetings"))
    fun.()
  end

  defp form, do: %{"name" => "Racer", "email" => "racer@example.com", "message" => ""}
end
