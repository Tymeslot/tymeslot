defmodule Tymeslot.Polls.ConfirmTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Confirm
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks

  @moduletag :integration
  @moduletag :polls

  setup do
    TestMocks.resolve_booking_calendars()
    user = insert(:user)
    _profile = insert(:profile, user: user)

    poll =
      insert(:poll, user: user, status: :open, timezone: "Europe/Berlin", meeting_type_id: nil)

    slot_start = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
    slot_end = DateTime.add(slot_start, 1, :hour)

    slot =
      insert(:poll_time_slot, poll: poll, start_time: slot_start, end_time: slot_end)

    %{user: user, poll: poll, slot: slot}
  end

  describe "confirm/3" do
    test "picks the first available voter (not the first registrant) and mints a meeting",
         %{user: user, poll: poll, slot: slot} do
      Polls.subscribe(poll.id)

      # Alice registered first but voted :no; Bob registered later and voted :yes.
      t0 = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      alice =
        insert(:poll_participant,
          poll: poll,
          name: "Alice",
          email: "alice@example.com",
          timezone: "America/New_York",
          inserted_at: t0
        )

      bob =
        insert(:poll_participant,
          poll: poll,
          name: "Bob",
          email: "bob@example.com",
          timezone: "Europe/London",
          inserted_at: DateTime.add(t0, 60, :second)
        )

      insert(:poll_vote, participant: alice, time_slot: slot, response: :no)
      insert(:poll_vote, participant: bob, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

      # Bob is the primary attendee: the first participant available for the slot.
      assert meeting.attendee_name == "Bob"
      assert meeting.attendee_email == "bob@example.com"
      assert meeting.attendee_timezone == "Europe/London"
      assert meeting.title == poll.title
      assert DateTime.compare(meeting.start_time, slot.start_time) == :eq
      assert DateTime.compare(meeting.end_time, slot.end_time) == :eq
      assert meeting.organizer_user_id == user.id

      # The host manages the meeting: everyone is a guest, Bob included, and
      # nobody holds a booking they could move or cancel for the rest.
      assert meeting.managed_by_host
      guest_emails = meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email)
      assert Enum.sort(guest_emails) == ["alice@example.com", "bob@example.com"]

      # The poll is now confirmed and points at the meeting.
      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :confirmed
      assert reloaded.confirmed_meeting_id == meeting.id
      assert reloaded.confirmed_at

      assert_receive {:poll_updated, broadcast_id}
      assert broadcast_id == poll.id
    end

    test "breaks a same-second registration tie deterministically",
         %{user: user, poll: poll, slot: slot} do
      # `inserted_at` is second-precision, so two strangers following the same
      # poll link routinely share one. Inserted in the order that puts the
      # tie-break at odds with physical row order: without a total ordering,
      # the preload hands back whatever the table scan produces, and the
      # primary attendee becomes a coin flip between two people who both voted
      # for the slot.
      registered_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      bob =
        insert(:poll_participant,
          poll: poll,
          name: "Bob",
          email: "bob@example.com",
          inserted_at: registered_at
        )

      ada =
        insert(:poll_participant,
          poll: poll,
          name: "Ada",
          email: "ada@example.com",
          inserted_at: registered_at
        )

      insert(:poll_vote, participant: bob, time_slot: slot, response: :yes)
      insert(:poll_vote, participant: ada, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)

      assert meeting.attendee_email == "ada@example.com"

      guest_emails = meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email)
      assert Enum.sort(guest_emails) == ["ada@example.com", "bob@example.com"]
    end

    test "falls back to the timezone of the poll when the primary has none",
         %{user: user, poll: poll, slot: slot} do
      participant =
        insert(:poll_participant, poll: poll, email: "solo@example.com", timezone: nil)

      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.attendee_timezone == poll.timezone
    end

    test "writes the meeting's emails in the primary's language",
         %{user: user, poll: poll, slot: slot} do
      participant = insert(:poll_participant, poll: poll, email: "solo@example.com", locale: "de")
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.attendee_locale == "de"
    end

    test "names the primary by address when they were invited without a name and never voted",
         %{user: user, poll: poll, slot: slot} do
      insert(:poll_participant, poll: poll, name: nil, email: "ada@example.com")

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.attendee_name == "ada@example.com"
      assert meeting.attendee_email == "ada@example.com"
    end

    test "carries the poll's description onto the meeting as the organiser's note",
         %{user: user, poll: poll, slot: slot} do
      poll = poll |> Changeset.change(description: "Bring the Q3 numbers.") |> Repo.update!()

      participant = insert(:poll_participant, poll: poll, email: "solo@example.com")
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.organizer_note == "Bring the Q3 numbers."
      assert meeting.attendee_message == nil
    end

    test "still confirms a poll whose description predates the length cap, cutting the note to fit",
         %{user: user, poll: poll, slot: slot} do
      max = MeetingSchema.organizer_note_max_length()
      long = String.duplicate("a", max + 500)
      poll = poll |> Changeset.change(description: long) |> Repo.update!()

      participant = insert(:poll_participant, poll: poll, email: "solo@example.com")
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.organizer_note == String.duplicate("a", max)
    end

    test "returns :slot_taken when the organiser already has a meeting at that time",
         %{user: user, poll: poll, slot: slot} do
      insert(:poll_participant, poll: poll, email: "voter@example.com")

      insert(:meeting,
        organizer_user_id: user.id,
        status: :confirmed,
        start_time: slot.start_time,
        end_time: slot.end_time
      )

      assert {:error, :slot_taken} = Confirm.confirm(poll.id, slot.id, user.id)

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
      assert reloaded.confirmed_meeting_id == nil
    end

    test "does not mislabel a non-conflict booking failure as :slot_taken",
         %{user: user, poll: poll, slot: slot} do
      # Primary attendee is valid and available for the slot.
      primary = insert(:poll_participant, poll: poll, name: "Valid", email: "valid@example.com")
      insert(:poll_vote, participant: primary, time_slot: slot, response: :yes)

      # A second participant carries a malformed email (inserted straight via the
      # factory, bypassing registration validation). It becomes a guest, so the
      # guest insert fails inside the booking transaction and the ad-hoc path
      # surfaces a generic, non-conflict failure.
      insert(:poll_participant, poll: poll, email: "not-an-email")

      assert {:error, reason} = Confirm.confirm(poll.id, slot.id, user.id)
      refute reason == :slot_taken

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
      assert reloaded.confirmed_meeting_id == nil
    end

    test "returns :slot_in_past when the slot has already started",
         %{user: user, poll: poll} do
      insert(:poll_participant, poll: poll)

      past_start = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

      past_slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: past_start,
          end_time: DateTime.add(past_start, 1, :hour)
        )

      assert {:error, :slot_in_past} = Confirm.confirm(poll.id, past_slot.id, user.id)
    end

    test "returns :invalid_slot when the slot does not belong to the poll",
         %{user: user, poll: poll} do
      insert(:poll_participant, poll: poll)
      other_slot = insert(:poll_time_slot)

      assert {:error, :invalid_slot} = Confirm.confirm(poll.id, other_slot.id, user.id)
    end

    test "returns :invalid_slot for a slot id that is not a UUID, and leaves the poll open",
         %{user: user, poll: poll} do
      insert(:poll_participant, poll: poll)

      assert {:error, :invalid_slot} = Confirm.confirm(poll.id, "not-a-uuid", user.id)
      assert {:error, :invalid_slot} = Confirm.confirm(poll.id, nil, user.id)
      assert Repo.reload!(poll).status == :open
    end

    test "returns :not_found for a poll id that is not a UUID", %{user: user, slot: slot} do
      assert {:error, :not_found} = Confirm.confirm("not-a-uuid", slot.id, user.id)
      assert {:error, :not_found} = Confirm.confirm(nil, slot.id, user.id)
    end

    test "returns :not_found for a different owner", %{poll: poll, slot: slot} do
      other_user = insert(:user)
      assert {:error, :not_found} = Confirm.confirm(poll.id, slot.id, other_user.id)
    end

    test "returns :not_open for an already-confirmed poll",
         %{user: user, poll: poll, slot: slot} do
      insert(:poll_participant, poll: poll)
      {:ok, confirmed} = poll |> Changeset.change(status: :confirmed) |> Repo.update()

      assert {:error, :not_open} = Confirm.confirm(confirmed.id, slot.id, user.id)
    end

    test "returns :no_participants when the poll has no participants",
         %{user: user, poll: poll, slot: slot} do
      assert {:error, :no_participants} = Confirm.confirm(poll.id, slot.id, user.id)
    end
  end

  describe "confirm/3 on a poll the host answered too" do
    # The host's entry is matched by address, whatever its case.
    defp host_entry(user, poll, slot, inserted_at) do
      host =
        insert(:poll_participant,
          poll: poll,
          name: "Host",
          email: String.upcase(user.email),
          inserted_at: inserted_at
        )

      insert(:poll_vote, participant: host, time_slot: slot, response: :yes)
      host
    end

    test "makes the first available participant besides the host the attendee",
         %{user: user, poll: poll, slot: slot} do
      t0 = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
      host_entry(user, poll, slot, t0)

      bob =
        insert(:poll_participant,
          poll: poll,
          name: "Bob",
          email: "bob@example.com",
          inserted_at: DateTime.add(t0, 60, :second)
        )

      insert(:poll_vote, participant: bob, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.attendee_email == "bob@example.com"
      assert meeting.organizer_user_id == user.id
    end

    test "does not invite the host to their own meeting as a guest",
         %{user: user, poll: poll, slot: slot} do
      t0 = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)

      alice =
        insert(:poll_participant,
          poll: poll,
          name: "Alice",
          email: "alice@example.com",
          inserted_at: t0
        )

      insert(:poll_vote, participant: alice, time_slot: slot, response: :yes)
      host_entry(user, poll, slot, DateTime.add(t0, 60, :second))

      carol =
        insert(:poll_participant,
          poll: poll,
          name: "Carol",
          email: "carol@example.com",
          inserted_at: DateTime.add(t0, 120, :second)
        )

      insert(:poll_vote, participant: carol, time_slot: slot, response: :no)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.attendee_email == "alice@example.com"

      guest_emails = meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email)
      assert "carol@example.com" in guest_emails
      refute String.downcase(user.email) in guest_emails
    end

    test "returns :no_participants when only the host answered, and mints nothing",
         %{user: user, poll: poll, slot: slot} do
      host_entry(user, poll, slot, DateTime.utc_now(:second))

      assert {:error, :no_participants} = Confirm.confirm(poll.id, slot.id, user.id)
      assert Repo.aggregate(MeetingSchema, :count) == 0

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
    end
  end

  describe "confirm/3 against the host's time off" do
    # The host lives in Berlin, so every period below is wall-clock there and
    # a slot's UTC instant lands on a different day near midnight.
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "Europe/Berlin")
      poll = insert(:poll, user: user, status: :open, timezone: "Europe/Berlin")
      participant = insert(:poll_participant, poll: poll, email: "voter@example.com")

      %{user: user, profile: profile, poll: poll, participant: participant}
    end

    # A slot of `minutes` starting at `time` on `date`, Berlin wall-clock.
    defp berlin_slot(poll, participant, date, time, minutes) do
      start_time = date |> DateTime.new!(time, "Europe/Berlin") |> DateTime.shift_zone!("Etc/UTC")
      slot_end = DateTime.add(start_time, minutes, :minute)
      slot = insert(:poll_time_slot, poll: poll, start_time: start_time, end_time: slot_end)
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)
      slot
    end

    defp day_off!(profile, date) do
      {:ok, period} = TimeOff.create(profile.id, %{starts_on: date, ends_on: date})
      period
    end

    defp meeting_count(user_id) do
      Repo.aggregate(from(m in MeetingSchema, where: m.organizer_user_id == ^user_id), :count)
    end

    test "refuses a slot inside time off entered after the poll went out, and mints nothing",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      slot = berlin_slot(poll, participant, day, ~T[10:00:00], 60)

      # The poll and its votes exist before the host books the day off.
      day_off!(profile, day)

      assert {:error, :time_off} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting_count(user.id) == 0

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :open
      assert reloaded.confirmed_meeting_id == nil
    end

    test "refuses a slot that only runs into time off after midnight in the host's timezone",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      # 23:30 to 00:30 Berlin: on `day` in UTC throughout, yet its last half
      # hour is on the day off.
      slot = berlin_slot(poll, participant, day, ~T[23:30:00], 60)
      day_off!(profile, Date.add(day, 1))

      assert {:error, :time_off} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting_count(user.id) == 0
    end

    test "refuses a slot inside part-day time off",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      slot = berlin_slot(poll, participant, day, ~T[14:00:00], 30)

      {:ok, _period} =
        TimeOff.create(profile.id, %{starts_on: day, ends_on: day, start_time: ~T[13:00:00]})

      assert {:error, :time_off} = Confirm.confirm(poll.id, slot.id, user.id)
    end

    test "confirms a slot that ends as the time off begins",
         %{user: user, profile: profile, poll: poll, participant: participant} do
      day = Date.add(Date.utc_today(), 10)
      slot = berlin_slot(poll, participant, day, ~T[23:00:00], 60)
      day_off!(profile, Date.add(day, 1))

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert DateTime.compare(meeting.start_time, slot.start_time) == :eq

      {:ok, reloaded} = Polls.get_poll_for_host(poll.id, user.id)
      assert reloaded.status == :confirmed
    end
  end

  describe "confirm/3 next to another of the host's meetings" do
    # The host pads what bookers may pick by 15 minutes either side, and has a
    # meeting the poll's time starts five minutes after.
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)

      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        buffer_before_minutes: 15,
        buffer_after_minutes: 15
      )

      other_start = DateTime.utc_now() |> DateTime.add(4, :day) |> DateTime.truncate(:second)

      other =
        insert(:meeting,
          organizer_user_id: user.id,
          status: :confirmed,
          start_time: other_start,
          end_time: DateTime.add(other_start, 30, :minute)
        )

      slot_start = DateTime.add(other.end_time, 5, :minute)

      %{user: user, slot_start: slot_start, slot_end: DateTime.add(slot_start, 30, :minute)}
    end

    test "confirms a time inside the host's buffers, which shape only what bookers pick", ctx do
      poll =
        insert(:poll,
          user: ctx.user,
          status: :open,
          timezone: "Europe/Berlin",
          meeting_type_id: nil
        )

      slot =
        insert(:poll_time_slot, poll: poll, start_time: ctx.slot_start, end_time: ctx.slot_end)

      participant = insert(:poll_participant, poll: poll, email: "voter@example.com")
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, ctx.user.id)
      assert DateTime.compare(meeting.start_time, ctx.slot_start) == :eq
      assert meeting_count(ctx.user.id) == 2
    end

    test "Quick Add at that time is still padded by the buffers and refused", ctx do
      assert {:error, :time_conflict} =
               EventCreation.run_create_ad_hoc_meeting(%{
                 title: "Quick sync",
                 start_time: ctx.slot_start,
                 end_time: ctx.slot_end,
                 attendee_name: "Jane Doe",
                 attendee_email: "jane@example.com",
                 organizer_user_id: ctx.user.id
               })

      assert meeting_count(ctx.user.id) == 1
    end
  end

  describe "confirm/3 choosing the meeting's calendar" do
    setup %{user: user, poll: poll, slot: slot} do
      primary = insert(:calendar_integration, user: user)

      user.id
      |> Profiles.get_profile()
      |> Changeset.change(primary_calendar_integration_id: primary.id)
      |> Repo.update!()

      participant = insert(:poll_participant, poll: poll)
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)

      %{primary: primary}
    end

    test "books into the host's calendar when the poll's meeting type names none",
         %{user: user, poll: poll, slot: slot, primary: primary} do
      meeting_type = insert(:meeting_type, user: user, calendar_integration_id: nil)
      poll |> Changeset.change(meeting_type_id: meeting_type.id) |> Repo.update!()

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.calendar_integration_id == primary.id
    end

    test "books into the calendar the poll's meeting type names",
         %{user: user, poll: poll, slot: slot} do
      chosen = insert(:calendar_integration, user: user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          calendar_integration_id: chosen.id,
          target_calendar_id: "team-calendar"
        )

      poll |> Changeset.change(meeting_type_id: meeting_type.id) |> Repo.update!()

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.calendar_integration_id == chosen.id
      assert meeting.calendar_path == "team-calendar"
    end
  end
end
