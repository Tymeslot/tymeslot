defmodule Tymeslot.Meetings.MeetingTransitionQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Repo

  describe "transition_from_awaiting_approval/2 unique-violation handling" do
    test "returns {:error, :slot_taken} instead of raising when the target slot is already occupied" do
      organizer = insert(:user)
      taken_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user_id: organizer.id,
        start_time: taken_time,
        end_time: DateTime.add(taken_time, 3600, :second),
        status: :confirmed
      )

      held_start = DateTime.add(taken_time, 7200, :second)

      held =
        insert(:meeting,
          organizer_user_id: organizer.id,
          start_time: held_start,
          end_time: DateTime.add(held_start, 3600, :second),
          status: :awaiting_approval
        )

      # `changes` is a plain keyword list — the function's contract allows any
      # column, not only `status`. Moving this held row's own start_time onto
      # the already-occupied slot is the most direct way to trigger the same
      # unique-index collision the raw `Repo.update_all` has no changeset to
      # translate.
      assert {:error, :slot_taken} =
               MeetingTransitionQueries.transition_from_awaiting_approval(
                 held.id,
                 status: :confirmed,
                 start_time: taken_time
               )

      reloaded = Repo.get!(MeetingSchema, held.id)
      assert reloaded.status == :awaiting_approval
      assert reloaded.start_time == held.start_time
    end
  end

  describe "transition_from_awaiting_verification/3" do
    test "the verification transition moves only a held booking" do
      held = insert(:meeting, status: :awaiting_verification)
      confirmed = insert(:meeting, status: :confirmed)

      assert {:ok, %{status: :confirmed}} =
               MeetingTransitionQueries.transition_from_awaiting_verification(held.id,
                 status: :confirmed
               )

      assert {:error, :not_awaiting_verification} =
               MeetingTransitionQueries.transition_from_awaiting_verification(confirmed.id,
                 status: :cancelled
               )

      assert Repo.reload!(confirmed).status == :confirmed
    end

    test "two transitions race and one wins" do
      held = insert(:meeting, status: :awaiting_verification)

      results =
        for _attempt <- 1..2 do
          MeetingTransitionQueries.transition_from_awaiting_verification(held.id,
            status: :confirmed
          )
        end

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert {:error, :not_awaiting_verification} in results
    end

    test "with a deadline guard, refuses a booking whose deadline has passed" do
      now = DateTime.utc_now(:second)
      lapsed = insert(:meeting, status: :awaiting_verification, verification_deadline_at: now)

      open =
        insert(:meeting,
          status: :awaiting_verification,
          verification_deadline_at: DateTime.add(now, 60)
        )

      assert {:error, :not_awaiting_verification} =
               MeetingTransitionQueries.transition_from_awaiting_verification(
                 lapsed.id,
                 [status: :confirmed],
                 deadline_after: now
               )

      assert Repo.reload!(lapsed).status == :awaiting_verification

      assert {:ok, %{status: :confirmed}} =
               MeetingTransitionQueries.transition_from_awaiting_verification(
                 open.id,
                 [status: :confirmed],
                 deadline_after: now
               )

      # Releases carry no deadline guard.
      assert {:ok, %{status: :expired}} =
               MeetingTransitionQueries.transition_from_awaiting_verification(lapsed.id,
                 status: :expired
               )
    end
  end
end
