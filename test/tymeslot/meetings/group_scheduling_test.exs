defmodule Tymeslot.Meetings.GroupSchedulingTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Ecto.Changeset
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
      status: :confirmed,
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
      assert meeting.status == :confirmed
      assert participant.meeting_id == meeting.id
      assert participant.email == "one@example.com"
      assert [_only] = ParticipantQueries.list_live_for_meeting(meeting.id)
    end

    test "refuses a slot without an organiser instead of raising", ctx do
      attrs = %{
        meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)
        | organizer_user_id: nil
      }

      assert {:error, :organizer_required} =
               GroupScheduling.book_seat(attrs, seat_request("one@example.com"))

      assert Repo.all(MeetingSchema) == []
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

    test "with :join_only, refuses rather than creates when no live meeting is there", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:error, :slot_full} =
               GroupScheduling.book_seat(attrs, seat_request("one@example.com"), join_only: true)

      assert Repo.all(MeetingSchema) == []
    end

    test "with :join_only, still joins a live meeting", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      {:ok, %{meeting: meeting}} =
        GroupScheduling.book_seat(attrs, seat_request("one@example.com"))

      assert {:ok, %{meeting: %{id: id}, created_meeting?: false}} =
               GroupScheduling.book_seat(attrs, seat_request("two@example.com"), join_only: true)

      assert id == meeting.id
    end

    test "returns :time_conflict when another meeting blocks the window", ctx do
      blocker_start = DateTime.add(ctx.start_time, -15, :minute)

      insert(:meeting,
        organizer_user_id: ctx.user.id,
        start_time: blocker_start,
        end_time: DateTime.add(blocker_start, 30, :minute),
        status: :confirmed
      )

      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:error, :time_conflict} =
               GroupScheduling.book_seat(attrs, seat_request("late@example.com"))
    end
  end

  # A first-booker collision on the `(organizer_user_id, start_time)` index,
  # staged by leaving a meeting already at the slot out of the conflict
  # check, as a writer skipping the schedule lock would. That callback runs
  # once per attempt, so it also counts them.
  describe "book_seat/3 — a first-booker index collision" do
    setup ctx do
      blocker =
        insert(:meeting,
          organizer_user_id: ctx.user.id,
          start_time: ctx.start_time,
          end_time: DateTime.add(ctx.start_time, 30, :minute),
          status: :confirmed
        )

      test_pid = self()

      %{
        attrs: meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
        exclude: fn ->
          send(test_pid, :attempt)
          blocker.uid
        end
      }
    end

    test "on its own transaction, is retried and then surfaces the changeset", ctx do
      assert {:error, %Ecto.Changeset{} = changeset} =
               GroupScheduling.book_seat(ctx.attrs, seat_request("one@example.com"),
                 exclude_from_conflicts: ctx.exclude
               )

      assert MeetingSchema.unique_slot_violation?(changeset)
      assert_received :attempt
      assert_received :attempt
      refute_received :attempt
    end

    test "inside the caller's transaction, which it aborted, is refused as :slot_taken", ctx do
      opts = [in_outer_transaction: true, exclude_from_conflicts: ctx.exclude]

      assert {:error, :slot_taken} =
               Repo.transaction(fn ->
                 {:error, reason} =
                   GroupScheduling.book_seat(ctx.attrs, seat_request("one@example.com"), opts)

                 Repo.rollback(reason)
               end)

      assert_received :attempt
      refute_received :attempt

      assert Repo.aggregate(MeetingSchema, :count) == 1
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

    test "joining gates on the target meeting's own capacity, not the caller's seat request",
         ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      {:ok, %{meeting: meeting}} =
        GroupScheduling.book_seat(attrs, seat_request("one@example.com"))

      {:ok, _second} =
        GroupScheduling.book_seat(
          meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
          seat_request("two@example.com")
        )

      {:ok, _third} =
        GroupScheduling.book_seat(
          meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
          seat_request("three@example.com")
        )

      # The meeting is now full at its own snapshotted capacity (3). A
      # caller passing a higher max_participants — as if the type's live
      # value had since been raised — must still be rejected: the meeting's
      # own capacity governs its whole life, not the caller's number.
      assert {:error, :slot_full} =
               GroupScheduling.book_seat(
                 meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time),
                 seat_request("four@example.com", max_participants: 10)
               )

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

  describe "group_changeset/2 — status" do
    test "a group slot can be created awaiting verification", %{
      user: user,
      meeting_type: meeting_type,
      start_time: start_time
    } do
      attrs = meeting_attrs(user, meeting_type, start_time)

      held =
        MeetingSchema.group_changeset(
          %MeetingSchema{},
          Map.put(attrs, :status, :awaiting_verification)
        )

      assert Changeset.get_field(held, :status) == :awaiting_verification

      forced = MeetingSchema.group_changeset(%MeetingSchema{}, Map.put(attrs, :status, :pending))
      assert Changeset.get_field(forced, :status) == :confirmed
    end
  end

  describe "book_seat/2 — status is forced to confirmed" do
    # Only a seat hold (`:hold`) creates a slot awaiting payment; a caller's
    # status never does.
    test "a booked first seat confirms the slot whatever status the attrs carry", ctx do
      attrs = %{
        meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)
        | status: :awaiting_payment
      }

      assert {:ok, %{meeting: %MeetingSchema{status: :confirmed}, created_meeting?: true}} =
               GroupScheduling.book_seat(attrs, seat_request("one@example.com"))
    end

    test "a group meeting is created confirmed even if attrs omit status, preserving the single-row invariant",
         ctx do
      attrs_without_status =
        ctx.user
        |> meeting_attrs(ctx.meeting_type, ctx.start_time)
        |> Map.delete(:status)

      assert {:ok, %{meeting: meeting, created_meeting?: true}} =
               GroupScheduling.book_seat(attrs_without_status, seat_request("one@example.com"))

      assert meeting.status == :confirmed

      assert {:ok, %{meeting: joined, created_meeting?: false}} =
               GroupScheduling.book_seat(
                 ctx.user
                 |> meeting_attrs(ctx.meeting_type, ctx.start_time)
                 |> Map.delete(:status),
                 seat_request("two@example.com")
               )

      assert joined.id == meeting.id
      assert length(Repo.all(MeetingSchema)) == 1
    end
  end

  describe "book_seat/2 — one seat per person" do
    # Two tabs, one booker: the seat used to be taken twice, issuing two
    # management tokens so that cancelling "the" booking freed half of it.
    test "refuses a second live seat for the same address", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:ok, _first} = GroupScheduling.book_seat(attrs, seat_request("twice@example.com"))

      assert {:error, :already_booked} =
               GroupScheduling.book_seat(
                 Map.delete(attrs, :status),
                 seat_request("twice@example.com")
               )

      assert length(ParticipantQueries.list_live_for_meeting(hd(Repo.all(MeetingSchema)).id)) == 1
    end

    test "matches addresses regardless of case", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:ok, _first} = GroupScheduling.book_seat(attrs, seat_request("Mixed@Example.com"))

      assert {:error, :already_booked} =
               GroupScheduling.book_seat(
                 Map.delete(attrs, :status),
                 seat_request("mixed@example.com")
               )
    end

    test "lets someone rebook after giving up their seat", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      assert {:ok, %{participant: participant}} =
               GroupScheduling.book_seat(attrs, seat_request("again@example.com"))

      {:ok, _cancelled} = ParticipantQueries.cancel(participant)

      assert {:ok, _rebooked} =
               GroupScheduling.book_seat(
                 Map.delete(attrs, :status),
                 seat_request("again@example.com")
               )
    end

    # A group slot is one shared meeting row, so the old (meeting, email)
    # guest index made "my colleague was already invited by someone else" a
    # hard failure of the whole booking.
    test "lets two bookers invite the same guest", ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      # Four seats: two bookers, each bringing the same colleague.
      assert {:ok, _first} =
               GroupScheduling.book_seat(
                 attrs,
                 seat_request("one@example.com",
                   guest_emails: ["shared@example.com"],
                   max_participants: 4
                 )
               )

      assert {:ok, _second} =
               GroupScheduling.book_seat(
                 Map.delete(attrs, :status),
                 seat_request("two@example.com",
                   guest_emails: ["shared@example.com"],
                   max_participants: 4
                 )
               )
    end
  end

  # A venue can be deleted between the booking resolving the type's location
  # and the slot's row being written; the first seat must still be taken,
  # with the location written without the venue, as a solo booking is.
  test "a venue deleted mid-booking does not fail the first seat", ctx do
    venue = insert(:venue, user: ctx.user)
    Repo.delete!(venue)

    attrs =
      ctx.user
      |> meeting_attrs(ctx.meeting_type, ctx.start_time)
      |> Map.merge(%{venue_id: venue.id, location: "Main Hall (1 Market Square)"})

    assert {:ok, %{meeting: meeting, created_meeting?: true}} =
             GroupScheduling.book_seat(attrs, seat_request("one@example.com"))

    assert meeting.venue_id == nil
    assert meeting.location == "Main Hall (1 Market Square)"
  end

  describe "join_target/3" do
    setup ctx do
      attrs = meeting_attrs(ctx.user, ctx.meeting_type, ctx.start_time)

      {:ok, %{meeting: meeting}} =
        GroupScheduling.book_seat(attrs, seat_request("one@example.com"))

      %{meeting: meeting, attrs: attrs}
    end

    test "is the live meeting while it has the seats asked for", ctx do
      assert %MeetingSchema{id: id} =
               GroupScheduling.join_target(ctx.meeting_type.id, ctx.start_time, 2)

      assert id == ctx.meeting.id
    end

    test "accepts the start in any timezone", ctx do
      start_elsewhere = DateTime.shift_zone!(ctx.start_time, "America/New_York")

      assert %MeetingSchema{} =
               GroupScheduling.join_target(ctx.meeting_type.id, start_elsewhere, 1)
    end

    test "is nil when the booking asks for more seats than are left", ctx do
      assert GroupScheduling.join_target(ctx.meeting_type.id, ctx.start_time, 3) == nil
    end

    # The rule `book_seat/3` applies: a full meeting is not joined, so the
    # pre-checks keyed on this must not treat it as joinable either.
    test "is nil once the meeting is full, matching book_seat/3", ctx do
      {:ok, _seat} = GroupScheduling.book_seat(ctx.attrs, seat_request("two@example.com"))
      {:ok, _seat} = GroupScheduling.book_seat(ctx.attrs, seat_request("three@example.com"))

      assert GroupScheduling.join_target(ctx.meeting_type.id, ctx.start_time, 1) == nil

      assert {:error, :slot_full} =
               GroupScheduling.book_seat(ctx.attrs, seat_request("four@example.com"))
    end

    test "is nil at a time with no live meeting", ctx do
      later = DateTime.add(ctx.start_time, 1, :hour)
      assert GroupScheduling.join_target(ctx.meeting_type.id, later, 1) == nil
    end
  end
end
