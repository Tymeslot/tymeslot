defmodule Tymeslot.Scheduling.SharedAvailabilityTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Repo
  alias Tymeslot.Scheduling.SharedAvailability
  alias Tymeslot.Scheduling.SharedAvailability.Guest

  # Afternoons only, so the host's morning slots can never be the guest's.
  @afternoon %{is_available: true, start_time: ~T[13:00:00], end_time: ~T[17:00:00]}

  # No buffer, no notice, a long window: these tests are about who is free, not
  # about the policy clipping slots.
  @open_policy %{buffer_minutes: 0, min_advance_hours: 0, max_advance_booking_days: 365}

  defp insert_bookable_guest(username, opts \\ []) do
    %{user: user, profile: profile} =
      create_bookable_profile(
        profile: %{username: username},
        days: Enum.to_list(1..7),
        hours: Keyword.get(opts, :hours, @afternoon)
      )

    unless Keyword.get(opts, :calendar) == false,
      do: insert(:calendar_integration, user: user)

    insert(:meeting_type, user: user, is_private: Keyword.get(opts, :private_types, false))

    %{user: user, profile: profile}
  end

  defp host do
    %{user: user} = create_always_bookable_profile(profile: %{username: "marco"})
    user
  end

  defp no_events(_guest, _date), do: {:ok, []}

  describe "parse_usernames/1" do
    test "splits on commas, trims, lowercases and drops blanks and duplicates" do
      assert {:ok, ["michael", "sandy"]} =
               SharedAvailability.parse_usernames(" michael, Sandy ,,MICHAEL")
    end

    test "treats a missing parameter as no users" do
      assert {:ok, []} = SharedAvailability.parse_usernames(nil)
      assert {:ok, []} = SharedAvailability.parse_usernames("")
    end

    test "rejects a parameter that is not a string" do
      assert {:error, :invalid_usernames} = SharedAvailability.parse_usernames(["michael"])
    end

    test "rejects more users than a booking can have guests" do
      names = Enum.map_join(0..Guests.max_guests(), ",", &"user#{&1}")
      assert {:error, :invalid_usernames} = SharedAvailability.parse_usernames(names)
    end
  end

  describe "resolve/2" do
    test "resolves users with a bookable public page" do
      host = host()
      %{user: michael} = insert_bookable_guest("michael")

      assert {:ok, [%Guest{} = guest]} = SharedAvailability.resolve(["michael"], host.id)
      assert guest.user_id == michael.id
      assert guest.email == michael.email
      assert guest.username == "michael"
    end

    test "fails as a whole when any username is unknown" do
      host = host()
      insert_bookable_guest("michael")

      assert {:error, :unavailable_guests} =
               SharedAvailability.resolve(["michael", "nobody"], host.id)
    end

    test "refuses the host naming themselves" do
      host = host()
      insert(:calendar_integration, user: host)
      insert(:meeting_type, user: host)

      assert {:error, :unavailable_guests} = SharedAvailability.resolve(["marco"], host.id)
    end

    test "refuses a user without a connected calendar" do
      host = host()
      insert_bookable_guest("michael", calendar: false)

      assert {:error, :unavailable_guests} = SharedAvailability.resolve(["michael"], host.id)
    end

    test "refuses a user whose meeting types are all private" do
      host = host()
      insert_bookable_guest("michael", private_types: true)

      assert {:error, :unavailable_guests} = SharedAvailability.resolve(["michael"], host.id)
    end
  end

  describe "resolve_from_guest_emails/2" do
    test "keeps only guests who are bookable Tymeslot users" do
      host = host()
      %{user: michael} = insert_bookable_guest("michael")
      %{user: sandy} = insert_bookable_guest("sandy", calendar: false)

      assert [%Guest{username: "michael"}] =
               SharedAvailability.resolve_from_guest_emails(
                 [michael.email, sandy.email, "friend@example.com"],
                 host.id
               )
    end
  end

  describe "resolve_for_booking/2" do
    test "recovers the users among a booking's guests, for its host only" do
      host = host()
      %{user: michael} = insert_bookable_guest("michael")
      meeting = insert(:meeting, organizer_user_id: host.id)
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, [michael.email])

      assert [%Guest{username: "michael"}] =
               SharedAvailability.resolve_for_booking(meeting.uid, host.id)

      other_host = insert(:user)
      assert [] = SharedAvailability.resolve_for_booking(meeting.uid, other_host.id)
    end
  end

  describe "exclude_event/2" do
    test "drops the events carrying the booking's UID" do
      events = [%{uid: "booking"}, %{uid: "other"}, %{start_time: nil}]

      assert SharedAvailability.exclude_event(events, "booking") == [
               %{uid: "other"},
               %{start_time: nil}
             ]

      assert SharedAvailability.exclude_event(events, nil) == events
    end
  end

  describe "strictest_policy/2" do
    test "takes the largest buffer and notice and the shortest window" do
      host = host()
      %{profile: profile} = insert_bookable_guest("michael")

      Repo.update_all(
        from(s in AvailabilityScheduleSchema,
          where: s.profile_id == ^profile.id
        ),
        set: [buffer_minutes: 30, min_advance_hours: 1, advance_booking_days: 14]
      )

      {:ok, guests} = SharedAvailability.resolve(["michael"], host.id)
      host_config = %{buffer_minutes: 10, min_advance_hours: 24, max_advance_booking_days: 90}

      assert %{buffer_minutes: 30, min_advance_hours: 24, max_advance_booking_days: 14} =
               SharedAvailability.strictest_policy(host_config, guests)
    end

    test "leaves the config untouched without guests" do
      config = %{buffer_minutes: 10}
      assert SharedAvailability.strictest_policy(config, []) == config
    end
  end

  describe "filter_slots/7" do
    setup do
      host = host()
      insert_bookable_guest("michael")
      {:ok, guests} = SharedAvailability.resolve(["michael"], host.id)
      %{guests: guests, date: next_bookable_weekday()}
    end

    test "keeps only the host's slots within the guest's working hours", %{
      guests: guests,
      date: date
    } do
      host_slots = ["10:00 AM", "1:00 PM", "3:30 PM", "4:45 PM"]

      assert {:ok, ["1:00 PM", "3:30 PM"]} =
               SharedAvailability.filter_slots(
                 host_slots,
                 date,
                 30,
                 "Etc/UTC",
                 guests,
                 @open_policy,
                 &no_events/2
               )
    end

    test "drops slots the guest's calendar is busy for", %{guests: guests, date: date} do
      busy = %{
        start_time: DateTime.new!(date, ~T[13:00:00], "Etc/UTC"),
        end_time: DateTime.new!(date, ~T[14:00:00], "Etc/UTC")
      }

      assert {:ok, ["3:30 PM"]} =
               SharedAvailability.filter_slots(
                 ["1:00 PM", "3:30 PM"],
                 date,
                 30,
                 "Etc/UTC",
                 guests,
                 @open_policy,
                 fn _guest, _date -> {:ok, [busy]} end
               )
    end

    test "drops slots the guest hosts a Tymeslot booking in", %{
      guests: [guest] = guests,
      date: date
    } do
      insert(:meeting,
        organizer_user_id: guest.user_id,
        start_time: DateTime.new!(date, ~T[15:30:00], "Etc/UTC"),
        end_time: DateTime.new!(date, ~T[16:00:00], "Etc/UTC"),
        status: "confirmed"
      )

      assert {:ok, ["1:00 PM"]} =
               SharedAvailability.filter_slots(
                 ["1:00 PM", "3:30 PM"],
                 date,
                 30,
                 "Etc/UTC",
                 guests,
                 @open_policy,
                 &no_events/2
               )
    end

    test "passes a calendar read failure through", %{guests: guests, date: date} do
      assert {:error, :timeout} =
               SharedAvailability.filter_slots(
                 ["1:00 PM"],
                 date,
                 30,
                 "Etc/UTC",
                 guests,
                 @open_policy,
                 fn _guest, _date -> {:error, :timeout} end
               )
    end
  end

  describe "validate_guests_available/7" do
    setup do
      host = host()
      insert_bookable_guest("michael")
      {:ok, guests} = SharedAvailability.resolve(["michael"], host.id)
      %{guests: guests, date: next_bookable_weekday()}
    end

    test "accepts a time every guest is free for", %{guests: guests, date: date} do
      start = DateTime.new!(date, ~T[14:00:00], "Etc/UTC")

      assert :ok =
               SharedAvailability.validate_guests_available(
                 guests,
                 date,
                 start,
                 DateTime.add(start, 30, :minute),
                 "Etc/UTC",
                 @open_policy,
                 &no_events/2
               )
    end

    test "refuses a time outside a guest's working hours", %{guests: guests, date: date} do
      start = DateTime.new!(date, ~T[10:00:00], "Etc/UTC")

      assert {:error, :slot_unavailable} =
               SharedAvailability.validate_guests_available(
                 guests,
                 date,
                 start,
                 DateTime.add(start, 30, :minute),
                 "Etc/UTC",
                 @open_policy,
                 &no_events/2
               )
    end

    test "refuses a time a guest's calendar is busy for", %{guests: guests, date: date} do
      start = DateTime.new!(date, ~T[14:00:00], "Etc/UTC")
      busy = %{start_time: start, end_time: DateTime.add(start, 60, :minute)}

      assert {:error, :slot_unavailable} =
               SharedAvailability.validate_guests_available(
                 guests,
                 date,
                 start,
                 DateTime.add(start, 30, :minute),
                 "Etc/UTC",
                 @open_policy,
                 fn _guest, _date -> {:ok, [busy]} end
               )
    end
  end

  describe "merge_guest_emails/2" do
    test "puts the named users first so the guest cap cannot drop them" do
      guests = [%{email: "michael@example.com"}]

      assert SharedAvailability.merge_guest_emails(guests, ["friend@example.com"]) ==
               ["michael@example.com", "friend@example.com"]
    end
  end
end
