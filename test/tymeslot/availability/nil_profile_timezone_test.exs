defmodule Tymeslot.Availability.NilProfileTimezoneTest do
  @moduledoc """
  A host whose profile has no timezone set has one clock, not two: the booking
  page, the published free/busy feed and the time-off form's warning about
  bookings it covers all read the host's hours and time off on the default
  zone (`Tymeslot.Profiles.timezone/1`). They used to split, the booking page
  on the default zone and the other two on UTC, hours apart. A blank stored
  zone, or one the time-zone database does not know, is no zone either.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :availability

  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.FreeBusy
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: user, profile: profile} = create_bookable_profile(timezone: nil)
    date = next_bookable_weekday()
    zone = Profiles.get_default_timezone()

    # Time off from 11:00 to 14:00 on the host's clock.
    period =
      insert(:time_off_period,
        profile: profile,
        starts_on: date,
        ends_on: date,
        start_time: ~T[11:00:00],
        end_time: ~T[14:00:00]
      )

    %{user: user, profile: profile, date: date, zone: zone, period: period}
  end

  for {label, stored} <- [{"no", nil}, {"a blank", ""}, {"an unknown", "Not/AZone"}] do
    describe "a host with #{label} timezone" do
      setup ctx do
        Repo.update_all(from(p in ProfileSchema, where: p.id == ^ctx.profile.id),
          set: [timezone: unquote(stored)]
        )

        %{profile: Repo.reload!(ctx.profile)}
      end

      test "the booking page withholds the time off on the default zone", ctx do
        labels = ctx.profile |> offered(ctx.date, 60, timezone: ctx.zone) |> Enum.map(&label/1)

        assert labels != []
        refute "11:00 AM" in labels
        refute "1:00 PM" in labels
        assert "2:00 PM" in labels
      end

      test "the free/busy feed blocks the same hours", ctx do
        from = DateTime.add(DateTime.new!(ctx.date, ~T[00:00:00], "Etc/UTC"), -1, :day)
        to = DateTime.add(from, 3, :day)

        assert FreeBusy.busy_intervals(ctx.profile, from, to) == [
                 {local(ctx, ~T[11:00:00]), local(ctx, ~T[14:00:00])}
               ]
      end

      test "the time off warns about a booking inside it", ctx do
        start_time = local(ctx, ~T[11:30:00])

        meeting =
          insert(:meeting,
            organizer_user_id: ctx.user.id,
            start_time: start_time,
            end_time: DateTime.add(start_time, 30, :minute)
          )

        assert [%{id: id}] = TimeOff.conflicting_meetings(ctx.period)
        assert id == meeting.id
      end
    end
  end

  defp local(ctx, time),
    do: ctx.date |> DateTime.new!(time, ctx.zone) |> DateTime.shift_zone!("Etc/UTC")

  defp label(%{time: time}), do: time
  defp label(time) when is_binary(time), do: time
end
