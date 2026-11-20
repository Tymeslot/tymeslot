defmodule Tymeslot.InviteeData.HeldBookingsAvailabilityTest do
  @moduledoc """
  An erasure releasing a booking held for email confirmation announces the
  freed slot only once the erasure has committed. Announced earlier, an open
  booking page re-reads the slot while the hold still stands, and keeps it
  hidden. Run on a real connection staged by `Tymeslot.Test.RaceConductor`
  (see its moduledoc for why the module is synchronous and why `on_exit`
  deletes what it committed).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [unboxed: 1]

  alias Ecto.Adapters.SQL
  alias Ecto.UUID
  alias Tymeslot.Availability
  alias Tymeslot.InviteeData
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  @email "held-erasure@example.com"

  setup do
    %{rows: [[last_job_id]]} =
      unboxed(fn -> SQL.query!(Repo, "SELECT coalesce(max(id), 0) FROM oban_jobs", []) end)

    held =
      unboxed(fn ->
        host = insert(:user)
        insert(:awaiting_verification_meeting, organizer_user: host, attendee_email: @email)
      end)

    on_exit(fn ->
      unboxed(fn ->
        SQL.query!(Repo, "DELETE FROM oban_jobs WHERE id > $1", [last_job_id])
        SQL.query!(Repo, "DELETE FROM meetings WHERE id = $1", [UUID.dump!(held.id)])
        SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [held.organizer_user_id])
      end)
    end)

    RaceConductor.attach_parking()

    %{held: held}
  end

  test "the freed slot is announced after the erasure commits, not before", %{held: held} do
    test_pid = self()
    :ok = Availability.subscribe(held.organizer_user_id)

    eraser =
      Task.async(fn ->
        unboxed(fn ->
          # Parks inside the erasure's transaction, after the hold is released.
          RaceConductor.arm(RaceConductor.park_here(test_pid), &booking_payments_scrub?/1)
          InviteeData.erase(@email)
        end)
      end)

    assert_receive {:parked, eraser_pid}, 5_000
    refute_received {:availability_changed, _user_id}

    send(eraser_pid, :release)
    assert {:ok, %{meetings: 1}} = Task.await(eraser)

    assert_received {:availability_changed, organiser_id}
    assert organiser_id == held.organizer_user_id
    assert %{status: :cancelled} = unboxed(fn -> Repo.get!(MeetingSchema, held.id) end)
  end

  defp booking_payments_scrub?(metadata),
    do: metadata[:source] == "booking_payments" and metadata[:query] =~ "UPDATE"
end
