defmodule Tymeslot.Bookings.CreateRaceTest do
  @moduledoc """
  Two bookers submitting the same slot at once, through the whole booking
  flow, on real connections staged by `Tymeslot.Test.RaceConductor` (see its
  moduledoc for why the module is synchronous and why `on_exit` deletes what
  it committed).

  Both pass every check made before the booking transaction, since neither
  booking exists yet. Each contender parks right after inserting its
  meeting, so the winner holds the organiser's schedule lock while the loser
  waits on it and then finds the winner's meeting.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [create_always_bookable_profile: 0]
  import Tymeslot.MeetingTestHelpers, only: [build_form_data: 0, build_meeting_params: 2]
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.Create
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

    user = unboxed(fn -> create_always_bookable_profile().user end)
    last_job_id = unboxed(fn -> Repo.aggregate(Oban.Job, :max, :id) || 0 end)

    on_exit(fn ->
      unboxed(fn ->
        # The winning booking commits its follow-up jobs (emails, calendar sync).
        Repo.delete_all(from(j in Oban.Job, where: j.id > ^last_job_id))
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user}
  end

  test "two bookers of the same start: the loser is told the slot is taken", ctx do
    params = build_meeting_params(ctx.user, %{date: Date.add(Date.utc_today(), 5), time: "14:00"})

    results =
      race([
        fn hold -> book(params, hold) end,
        fn hold -> book(params, hold) end
      ])

    assert Enum.count(results, &match?({:ok, %MeetingSchema{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :slot_taken})) == 1

    assert unboxed(fn ->
             Repo.aggregate(
               from(m in MeetingSchema, where: m.organizer_user_id == ^ctx.user.id),
               :count
             )
           end) == 1
  end

  defp book(params, hold) do
    RaceConductor.arm(hold, RaceConductor.insert_into("meetings"))
    Create.execute(params, build_form_data())
  end
end
