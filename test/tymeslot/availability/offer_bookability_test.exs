defmodule Tymeslot.Availability.OfferBookabilityTest do
  @moduledoc """
  What a guest can book around an all-day event on a read-only calendar.

  A holiday feed marks its days free, and they used to stay bookable. Now an
  all-day event on a read-only calendar that blocks availability closes the
  day even when marked free, and the organiser's "Treat as Free" opens it
  again. Checked on the booking page (`Offer.slots_for_date/3`), in the
  guest's week view (`Offer.slots_for_range/4`, which reads the calendar
  fresh), in the calendar's bookable windows, and in the submit's own re-read
  of the calendars (`CalendarCheck.probe/3`), which must all agree.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability
  alias Tymeslot.Availability.Bookability
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Bookings.CalendarCheck
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    AvailabilityCache.clear_all()
    on_exit(&AvailabilityCache.clear_all/0)

    %{user: user, profile: profile} = create_bookable_profile()

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true, "primary" => true},
          %{"id" => "holidays", "name" => "Holidays", "selected" => true, "read_only" => true}
        ]
      )

    meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

    %{
      user: user,
      profile: profile,
      integration: integration,
      meeting_type: meeting_type,
      date: next_bookable_weekday()
    }
  end

  # An all-day event as the sync caches it, and as the live fetch returns it.
  defp holiday(ctx, attrs \\ %{}) do
    defaults = %{
      calendar_integration: ctx.integration,
      uid: "holiday-1",
      provider_event_id: "g-holiday-1",
      provider: "google",
      provider_calendar_id: "holidays",
      summary: "Bank holiday",
      all_day: true,
      start_date: ctx.date,
      end_date: Date.add(ctx.date, 1),
      start_at: nil,
      end_at: nil,
      transparency: "transparent"
    }

    row = insert(:provider_calendar_event, Map.merge(defaults, attrs))

    live = %{
      uid: row.provider_event_id,
      ical_uid: row.uid,
      summary: row.summary,
      all_day: row.all_day,
      start_time: row.start_date || row.start_at,
      end_time: row.end_date || row.end_at,
      status: "confirmed",
      transparency: row.transparency
    }

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, [live]}
    end)

    row
  end

  defp page(ctx, date), do: offered(ctx.profile, date, 30)

  # The guest's week view, which reads the calendar fresh rather than from
  # the booking-window cache.
  defp week(ctx, date) do
    request = %{profile: ctx.profile, user_timezone: ctx.profile.timezone, meeting_type: nil}

    {:ok, days} = Offer.slots_for_range(request, date, Date.add(date, 6), 30)
    Map.fetch!(days, Date.to_iso8601(date))
  end

  defp probe(ctx) do
    start = DateTime.new!(ctx.date, ~T[11:00:00], "Etc/UTC")

    CalendarCheck.probe(
      %{
        organizer_user_id: ctx.user.id,
        start_datetime: start,
        end_datetime: DateTime.add(start, 30, :minute)
      },
      Schedules.booking_config(ctx.user.id, nil)
    )
  end

  test "a free all-day event on a read-only calendar closes the day", ctx do
    holiday(ctx)

    assert page(ctx, ctx.date) == []
    assert "11:00 AM" in page(ctx, Date.add(ctx.date, 7))
  end

  test "the calendar's bookable windows close the day with the page", ctx do
    holiday(ctx)

    assert {:ok, []} =
             Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)
  end

  test "the week view closes the day, and Treat as Free opens it", ctx do
    row = holiday(ctx)

    assert week(ctx, ctx.date) == []

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, false)

    assert "11:00 AM" in week(ctx, ctx.date)
  end

  test "the submit's re-check refuses the day as well", ctx do
    holiday(ctx)

    assert {:error, :slot_unavailable} = probe(ctx)
  end

  test "Treat as Free opens the day on the page, the windows and the re-check", ctx do
    row = holiday(ctx)
    assert page(ctx, ctx.date) == []

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, false)

    assert "11:00 AM" in page(ctx, ctx.date)

    assert {:ok, [_window | _rest]} =
             Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)

    assert :ok = probe(ctx)
  end

  test "clearing the override closes the day again", ctx do
    row = holiday(ctx)
    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, false)
    assert "11:00 AM" in page(ctx, ctx.date)

    :ok = Bookability.clear(ctx.user.id, ctx.integration.id, row.uid)

    assert page(ctx, ctx.date) == []
  end

  test "Treat as Free frees an all-day event its calendar marks busy", ctx do
    row = holiday(ctx, %{transparency: "opaque", summary: "Office closed"})
    assert page(ctx, ctx.date) == []
    assert {:error, :slot_unavailable} = probe(ctx)

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, false)

    assert "11:00 AM" in page(ctx, ctx.date)
    assert :ok = probe(ctx)
  end

  test "a free all-day event on a writable calendar stays free", ctx do
    holiday(ctx, %{provider_calendar_id: "work"})

    assert "11:00 AM" in page(ctx, ctx.date)
  end

  test "Treat as Busy closes a day a writable calendar marks free", ctx do
    row = holiday(ctx, %{provider_calendar_id: "work"})

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, true)

    assert page(ctx, ctx.date) == []
  end

  test "a free timed event on a read-only calendar stays free", ctx do
    holiday(ctx, %{
      all_day: false,
      start_date: nil,
      end_date: nil,
      start_at: DateTime.new!(ctx.date, ~T[11:00:00.000000], "Etc/UTC"),
      end_at: DateTime.new!(ctx.date, ~T[12:00:00.000000], "Etc/UTC")
    })

    assert "11:00 AM" in page(ctx, ctx.date)
  end

  test "a read-only calendar set not to block keeps its days open", ctx do
    holiday(ctx)

    ctx.integration
    |> Changeset.change(
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true, "primary" => true},
        %{
          "id" => "holidays",
          "name" => "Holidays",
          "selected" => true,
          "read_only" => true,
          "blocks_availability" => false
        }
      ]
    )
    |> Repo.update!()

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    assert "11:00 AM" in page(ctx, ctx.date)
  end
end
