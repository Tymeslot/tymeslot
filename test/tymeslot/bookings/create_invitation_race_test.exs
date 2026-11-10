defmodule Tymeslot.Bookings.CreateInvitationRaceTest do
  @moduledoc """
  Two bookers submitting one invitation at once, at different times, through
  the whole booking flow, on real connections staged by
  `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).

  The times differ on purpose: at one time the organiser's slot conflict
  check would refuse the loser as `:slot_taken`, and the invitation would
  play no part. Both pass `Invitations.check_claimable/2` before either has
  inserted, so only the invitation index can refuse the loser. Each contender
  parks right after inserting its meeting, so the winner holds the
  organiser's schedule lock while the loser waits on it and then meets the
  index at its own insert.
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
  alias Tymeslot.Invitations
  alias Tymeslot.Invitations.InvitationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor
  alias Tymeslot.TestMocks

  @occupying [:confirmed, :pending, :awaiting_payment, :awaiting_approval]

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    {user, invitation} =
      unboxed(fn ->
        user = create_always_bookable_profile().user

        type =
          insert(:meeting_type,
            user: user,
            invitation_only: true,
            is_active: true,
            duration_minutes: 60
          )

        {:ok, invitation} = Invitations.create(user.id, type, %{})
        {user, invitation}
      end)

    last_job_id = unboxed(fn -> Repo.aggregate(Oban.Job, :max, :id) || 0 end)

    on_exit(fn ->
      unboxed(fn ->
        # The winning booking commits its follow-up jobs (emails, calendar sync).
        Repo.delete_all(from(j in Oban.Job, where: j.id > ^last_job_id))
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(i in InvitationSchema, where: i.id == ^invitation.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, invitation: invitation}
  end

  test "two bookings on one invitation at different times: exactly one wins", ctx do
    booking = fn day ->
      build_meeting_params(ctx.user, %{
        date: Date.add(Date.utc_today(), day),
        time: "14:00",
        meeting_type_id: ctx.invitation.meeting_type_id,
        invitation_id: ctx.invitation.id
      })
    end

    results =
      race([
        fn hold -> book(booking.(5), hold) end,
        fn hold -> book(booking.(6), hold) end
      ])

    assert Enum.count(results, &match?({:ok, %MeetingSchema{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invitation_unavailable})) == 1

    assert unboxed(fn ->
             Repo.aggregate(
               from(m in MeetingSchema,
                 where: m.invitation_id == ^ctx.invitation.id and m.status in ^@occupying
               ),
               :count
             )
           end) == 1
  end

  defp book(params, hold) do
    RaceConductor.arm(hold, RaceConductor.insert_into("meetings"))
    Create.execute(params, build_form_data())
  end
end
