defmodule Tymeslot.Availability.OpeningRaceTest do
  @moduledoc """
  An undo of "Open for booking" racing a change to the same weekday on the
  Availability page, on real connections, staged by
  `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).

  `Opening.restore/2` checks that the weekday still holds the hours the
  opening wrote, then writes the old ones back. Unless the check reads the
  row under a lock taken in the same transaction as the write, the change
  can commit between the two, and the undo overwrites it.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.Opening
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    host =
      unboxed(fn ->
        user = insert(:user)
        profile = insert(:profile, user: user)
        schedule = insert(:availability_schedule, profile: profile, is_default: true)

        # Monday as an every-week opening left it: widened from 11:00-17:00.
        insert(:weekly_availability,
          schedule: schedule,
          day_of_week: 1,
          is_available: true,
          start_time: ~T[11:00:00],
          end_time: ~T[19:00:00]
        )

        %{user: user, profile: profile, schedule: schedule}
      end)

    on_exit(fn ->
      # Profile, schedule and weekly rows go with the user.
      unboxed(fn -> Repo.delete_all(from(u in UserSchema, where: u.id == ^host.user.id)) end)
    end)

    RaceConductor.attach_parking()

    host
  end

  test "an undo racing a change to the weekday never overwrites the change", host do
    opened = %{
      kind: :weekly,
      schedule_id: host.schedule.id,
      day_of_week: 1,
      start_time: ~T[11:00:00],
      end_time: ~T[19:00:00],
      ends_next_day: false,
      previous: %{
        is_available: true,
        start_time: ~T[11:00:00],
        end_time: ~T[17:00:00],
        ends_next_day: false,
        override: nil
      }
    }

    [undo, _edit] =
      race([
        fn hold ->
          # Parks right after reading the weekday, before writing it back.
          RaceConductor.arm(hold, read_of("weekly_availability"), must_park: true)
          Opening.restore(host.user.id, opened)
        end,
        fn hold ->
          # Parks holding the row it has just written, before committing.
          Repo.transaction(fn ->
            {:ok, _day} =
              AvailabilityActions.update_day_hours(
                host.profile.id,
                host.schedule.id,
                1,
                "08:00",
                "20:00"
              )

            hold.(nil)
          end)
        end
      ])

    # Whichever goes first, the change made on the Availability page stands:
    # either the undo lands first and the change follows it, or the undo
    # sees the change and refuses.
    assert undo in [:ok, {:error, :changed}]

    assert %{start_time: ~T[08:00:00], end_time: ~T[20:00:00]} =
             unboxed(fn -> WeeklySchedule.get_day_availability(host.schedule.id, 1) end)
  end

  defp read_of(table),
    do: &(&1[:source] == table and String.starts_with?(&1[:query], "SELECT"))
end
