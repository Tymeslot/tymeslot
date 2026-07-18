defmodule Tymeslot.Meetings.GroupSchedulingTest do
  @moduledoc false

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
    meeting_type = insert(:meeting_type, user: user, max_participants: 3)

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

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

  defp seat_request(email, opts \\ []) do
    %{
      participant: %{
        name: "Booker #{email}",
        email: email,
        timezone: "Etc/UTC",
        locale: "en",
        custom_field_answers: %{}
      },
      guest_emails: Keyword.get(opts, :guest_emails, []),
      max_participants: Keyword.get(opts, :max_participants, 3)
    }
  end

  describe "book_seat/2 — first booker" do
    test "creates the meeting and the first participant", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:ok, %{meeting: meeting, participant: participant, created_meeting?: true}} =
               GroupScheduling.book_seat(attrs, seat_request("one@example.com"))

      assert meeting.attendee_email == nil
      assert meeting.attendee_name == nil
      assert meeting.status == "confirmed"
      assert participant.meeting_id == meeting.id
      assert participant.email == "one@example.com"
      assert [_only] = ParticipantQueries.list_live_for_meeting(meeting.id)
    end

    test "rejects a first booking whose guests alone exceed capacity", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      request =
        seat_request("greedy@example.com",
          guest_emails: ["g1@example.com", "g2@example.com", "g3@example.com"]
        )

      assert {:error, :slot_full} = GroupScheduling.book_seat(attrs, request)
      assert Repo.all(MeetingSchema) == []
    end

    test "returns :time_conflict when another meeting blocks the window", ctx do
      blocker_start = DateTime.add(ctx.start_time, -15, :minute)

      insert(:meeting,
        organizer_user_id: ctx.user.id,
        start_time: blocker_start,
        end_time: DateTime.add(blocker_start, 30, :minute),
        status: "confirmed"
      )

      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:error, :time_conflict} =
               GroupScheduling.book_seat(attrs, seat_request("late@example.com"))
    end
  end

  describe "book_seat/2 — joining and filling" do
    test "second booker joins the existing meeting", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      {:ok, %{meeting: meeting}} =
        GroupScheduling.book_seat(attrs, seat_request("one@example.com"))

      fresh_attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:ok, %{meeting: joined, participant: participant, created_meeting?: false}} =
               GroupScheduling.book_seat(fresh_attrs, seat_request("two@example.com"))

      assert joined.id == meeting.id
      assert participant.email == "two@example.com"
      assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
      assert length(Repo.all(MeetingSchema)) == 1
    end

    test "a full slot rolls back with :slot_full", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      for email <- ["a@example.com", "b@example.com", "c@example.com"] do
        assert {:ok, _booking} =
                 GroupScheduling.book_seat(
                   meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
                   seat_request(email)
                 )
      end

      assert {:error, :slot_full} =
               GroupScheduling.book_seat(attrs, seat_request("overflow@example.com"))

      [meeting] = Repo.all(MeetingSchema)
      assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 3
    end

    test "guests consume seats", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:ok, %{meeting: meeting}} =
               GroupScheduling.book_seat(
                 attrs,
                 seat_request("host@example.com",
                   guest_emails: ["g1@example.com", "g2@example.com"]
                 )
               )

      assert {:error, :slot_full} =
               GroupScheduling.book_seat(
                 meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
                 seat_request("late@example.com")
               )

      assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
    end
  end

  describe "book_seat/2 — first-booker unique-index retry" do
    test "gives up after one retry when the slot is occupied only at index level", ctx do
      insert(:meeting,
        organizer_user_id: ctx.user.id,
        start_time: ctx.start_time,
        end_time: DateTime.add(ctx.start_time, 30, :minute),
        status: "confirmed",
        reschedule_requested_at: DateTime.utc_now(:second)
      )

      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:error, %Ecto.Changeset{} = changeset} =
               GroupScheduling.book_seat(attrs, seat_request("racer@example.com"))

      assert changeset.errors[:organizer_user_id]
    end
  end
end
