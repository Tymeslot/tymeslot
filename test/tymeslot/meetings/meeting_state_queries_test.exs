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

  test "the query and struct forms of visibility agree on every row" do
    now = DateTime.utc_now(:second)
    base = DateTime.add(now, 1, :day)

    verification = [
      ungated: [],
      held: [verification_deadline_at: now],
      verified: [verification_deadline_at: now, email_verified_at: now]
    ]

    resolution = [unresolved: [], resolved: [approval_resolved_at: now]]

    rows =
      for {status, s} <- Enum.with_index(MeetingState.statuses()),
          {_kind, v_attrs} <- verification,
          {_res, r_attrs} <- resolution,
          reduce: [] do
        acc ->
          starts = DateTime.add(base, length(acc) + s, :hour)

          attrs =
            [status: status, start_time: starts, end_time: DateTime.add(starts, 30, :minute)] ++
              v_attrs ++ r_attrs

          [insert(:meeting, attrs) | acc]
      end

    ids = Enum.map(rows, & &1.id)

    by_query =
      Meeting
      |> where([m], m.id in ^ids)
      |> MeetingState.where_visible_to_organiser()
      |> select([m], m.id)
      |> Repo.all()
      |> MapSet.new()

    by_struct =
      Meeting
      |> where([m], m.id in ^ids)
      |> Repo.all()
      |> Enum.filter(&MeetingState.visible_to_organiser?/1)
      |> MapSet.new(& &1.id)

    # Anchor: both answers occur, so agreement is not two empty sets.
    assert MapSet.size(by_query) > 0 and MapSet.size(by_query) < length(ids)
    assert by_query == by_struct
  end
end
