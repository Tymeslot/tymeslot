defmodule Tymeslot.Meetings.GroupSchedulingConcurrencyTest do
  @moduledoc false

  # async: false so the Ecto sandbox runs in shared mode and the spawned
  # tasks reuse the test's DB connection (see refunds_concurrency_test.exs).
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 2)

    start_time =
      DateTime.utc_now()
      |> DateTime.add(6, :day)
      |> then(&%{&1 | hour: 9, minute: 0, second: 0, microsecond: {0, 0}})

    %{user: user, meeting_type: meeting_type, start_time: start_time}
  end

  defp meeting_attrs(user, meeting_type, start_time) do
    %{
      uid: UUID.generate(),
      title: meeting_type.name,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed",
      organizer_user_id: user.id,
      organizer_name: "Organiser",
      organizer_email: "organiser@example.com",
      meeting_type_id: meeting_type.id
    }
  end

  defp seat_request(email) do
    %{
      participant: %{
        name: "Booker #{email}",
        email: email,
        timezone: "Etc/UTC",
        locale: "en",
        custom_field_answers: %{}
      },
      guest_emails: [],
      max_participants: 2
    }
  end

  test "two bookers racing for the last seat: exactly one wins", ctx do
    {:ok, %{meeting: meeting}} =
      GroupScheduling.book_seat(
        meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
        seat_request("first@example.com")
      )

    tasks =
      for email <- ["race-a@example.com", "race-b@example.com"] do
        Task.async(fn ->
          GroupScheduling.book_seat(
            meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
            seat_request(email)
          )
        end)
      end

    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &match?({:ok, %{created_meeting?: false}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :slot_full}, &1)) == 1
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
  end

  test "two racing first bookers end up on one meeting", ctx do
    tasks =
      for email <- ["first-a@example.com", "first-b@example.com"] do
        Task.async(fn ->
          GroupScheduling.book_seat(
            meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
            seat_request(email)
          )
        end)
      end

    results = Task.await_many(tasks, 10_000)

    assert Enum.all?(results, &match?({:ok, _booking}, &1)),
           "expected both bookers to succeed, got: #{inspect(results)}"

    created_flags = Enum.map(results, fn {:ok, booking} -> booking.created_meeting? end)
    assert Enum.count(created_flags, & &1) == 1

    assert [meeting] = Repo.all(MeetingSchema)
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
  end
end
