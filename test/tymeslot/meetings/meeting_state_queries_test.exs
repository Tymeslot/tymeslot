defmodule Tymeslot.Meetings.MeetingStateQueriesTest do
  @moduledoc """
  The query-side counterparts in `Tymeslot.Meetings.MeetingState` for the
  `:awaiting_verification` status and the verification columns.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :database

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  test "an unverified booking occupies its slot" do
    start_time = DateTime.add(DateTime.utc_now(:second), 1, :day)

    held =
      insert(:meeting,
        status: :awaiting_verification,
        verification_deadline_at: DateTime.add(start_time, -1, :hour),
        start_time: start_time,
        end_time: DateTime.add(start_time, 1800, :second)
      )

    ids = Meeting |> MeetingState.where_slot_live() |> Repo.all() |> Enum.map(& &1.id)
    assert held.id in ids
  end

  test "an unverified booking expects no calendar event" do
    held = insert(:meeting, status: :awaiting_verification)

    refute held.id in (Meeting
                       |> MeetingState.where_expects_calendar_event()
                       |> Repo.all()
                       |> Enum.map(& &1.id))
  end

  test "visibility follows the columns, not the status" do
    deadline = DateTime.add(DateTime.utc_now(:second), 1, :hour)

    ungated = insert(:meeting, status: :confirmed)
    held = insert(:meeting, status: :awaiting_verification, verification_deadline_at: deadline)

    lapsed =
      insert(:meeting,
        status: :expired,
        verification_deadline_at: deadline,
        email_verified_at: nil
      )

    verified =
      insert(:meeting,
        status: :confirmed,
        verification_deadline_at: deadline,
        email_verified_at: DateTime.utc_now(:second)
      )

    ids = [ungated.id, held.id, lapsed.id, verified.id]

    visible =
      Meeting
      |> where([m], m.id in ^ids)
      |> MeetingState.where_visible_to_organiser()
      |> Repo.all()
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert visible == Enum.sort([ungated.id, verified.id])

    for {meeting, expected} <- [{ungated, true}, {held, false}, {lapsed, false}, {verified, true}] do
      assert MeetingState.visible_to_organiser?(Repo.reload!(meeting)) == expected
    end
  end
end
