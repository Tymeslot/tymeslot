defmodule Tymeslot.Availability.OfferRescheduleTest do
  @moduledoc """
  What a reschedule page offers when the host has a booking limit.

  Moving a booking does not count the booking itself against the host's caps:
  `Reschedule.execute/4` excludes the meeting being moved from the count.
  The page has to offer by the same rule, or a booker holding the only slot
  of a day capped at one sees that whole day greyed out, although the submit
  would accept any other time on it.

  The exclusion is keyed on a meeting the page can prove is the organiser's,
  never on the raw link parameter, so an arbitrary value can neither lift a
  cap nor mint its own cache entries.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Infrastructure.{AvailabilityCache, CacheStore}
  alias Tymeslot.Scheduling.ThemeFlow
  alias Tymeslot.TestMocks

  @timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} =
      create_always_bookable_profile(timezone: @timezone, profile: %{max_bookings_per_day: 1})

    meeting_type = insert(:meeting_type, user: user, duration_minutes: 60)
    date = Date.add(Date.utc_today(), 5)
    start_time = DateTime.new!(date, ~T[14:00:00], @timezone)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 60, :minute),
        duration: 60
      )

    %{user: user, profile: profile, meeting_type: meeting_type, meeting: meeting, date: date}
  end

  describe "slots_for_date/3 on a day at its booking limit" do
    test "offers the rest of the day to the booking being moved, and the move succeeds",
         %{user: user, meeting: meeting, date: date} = context do
      slots = slots(context, meeting.uid)

      assert "10:00 AM" in slots

      assert {:ok, moved} =
               Reschedule.execute(
                 meeting.uid,
                 %{
                   date: Date.to_iso8601(date),
                   time: "10:00 AM",
                   duration: "60min",
                   user_timezone: @timezone
                 },
                 user.id
               )

      assert moved.start_time == DateTime.new!(date, ~T[10:00:00], @timezone)
    end

    test "offers nothing to anyone else", context do
      assert slots(context, nil) == []
    end

    test "offers nothing for a link naming no meeting of this organiser", context do
      %{user: other_user} = create_always_bookable_profile(timezone: @timezone)
      other_start = DateTime.new!(context.date, ~T[09:00:00], @timezone)

      other_meeting =
        insert(:meeting,
          organizer_user_id: other_user.id,
          start_time: other_start,
          end_time: DateTime.add(other_start, 60, :minute)
        )

      assert slots(context, UUID.generate()) == []
      assert slots(context, other_meeting.uid) == []
    end
  end

  describe "days_in_range/4 on a day at its booking limit" do
    test "shows the day bookable to the booking being moved", %{meeting: meeting} = context do
      assert Map.fetch!(days(context, meeting.uid), Date.to_iso8601(context.date))
    end

    # The range result is cached. A reschedule viewer's map must not be served
    # to a public viewer of the same range, who is still at the cap.
    test "does not serve the mover's view to the public afterwards",
         %{meeting: meeting} = context do
      assert Map.fetch!(days(context, meeting.uid), Date.to_iso8601(context.date))

      refute Map.fetch!(days(context, nil), Date.to_iso8601(context.date))
      refute Map.fetch!(days(context, UUID.generate()), Date.to_iso8601(context.date))
    end

    test "caches nothing under a link value it could not prove", %{meeting: meeting} = context do
      unproven = UUID.generate()

      days(context, meeting.uid)
      days(context, unproven)

      # Anchor: the proven uid does get its own entry, so the miss below is the
      # proof being required rather than the key never being written.
      assert {:ok, _days} =
               CacheStore.lookup(:availability_cache, range_key(context, meeting.uid))

      assert CacheStore.lookup(:availability_cache, range_key(context, unproven)) == :miss
    end
  end

  describe "a request carrying the page's loaded booking" do
    # The page loaded the booking when it applied its link
    # (`ThemeFlow.reschedule_context/2`); a fetch takes that load rather than
    # looking the uid up again.
    test "offers the rest of the day without looking the booking up again",
         %{user: user, meeting: meeting} = context do
      {:ok, loaded} = ThemeFlow.reschedule_context(meeting.uid, user.id)
      count_lookups_of(meeting.uid)

      assert "10:00 AM" in slots(context, meeting.uid, loaded)
      refute_received {:booking_lookup, _uid}
    end

    # Only a load of this organiser's own booking stands in for the lookup;
    # any other is looked up, and found to be no booking of theirs.
    test "looks up a load of another organiser's booking rather than trusting it", context do
      %{user: other_user} = create_always_bookable_profile(timezone: @timezone)
      other_start = DateTime.new!(context.date, ~T[09:00:00], @timezone)

      other_meeting =
        insert(:meeting,
          organizer_user_id: other_user.id,
          start_time: other_start,
          end_time: DateTime.add(other_start, 60, :minute)
        )

      {:ok, loaded} = ThemeFlow.reschedule_context(other_meeting.uid, other_user.id)
      count_lookups_of(other_meeting.uid)

      assert slots(context, other_meeting.uid, loaded) == []
      assert_received {:booking_lookup, _uid}
    end

    test "ignores a load of a booking other than the one the link names",
         %{user: user, meeting: meeting} = context do
      {:ok, loaded} = ThemeFlow.reschedule_context(meeting.uid, user.id)

      assert slots(context, UUID.generate(), loaded) == []
    end
  end

  # The lookup by uid, which names the uid first; the booking-limit count
  # that leaves the booking out names it too, last.
  defp count_lookups_of(uid) do
    parent = self()
    handler_id = "offer-reschedule-lookup-#{uid}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source, params: params}, _config ->
        if source == "meetings" and match?([^uid | _], params),
          do: send(parent, {:booking_lookup, uid})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp request(%{profile: profile, meeting_type: meeting_type}, reschedule_uid, loaded \\ nil) do
    %{
      profile: profile,
      user_timezone: @timezone,
      meeting_type: meeting_type,
      reschedule_uid: reschedule_uid,
      reschedule: loaded
    }
  end

  defp slots(context, reschedule_uid, loaded \\ nil) do
    {:ok, slots} =
      context
      |> request(reschedule_uid, loaded)
      |> Offer.slots_for_date(Date.to_iso8601(context.date), 60)

    slots
  end

  defp days(context, reschedule_uid) do
    {:ok, days} =
      context
      |> request(reschedule_uid)
      |> Offer.days_in_range(context.date, Date.add(context.date, 1), 60)

    days
  end

  defp range_key(%{user: user, meeting_type: meeting_type, date: date}, uid) do
    AvailabilityCache.availability_range_key(
      user.id,
      date,
      Date.add(date, 1),
      @timezone,
      60,
      meeting_type.id,
      uid
    )
  end
end
