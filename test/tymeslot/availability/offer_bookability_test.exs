defmodule Tymeslot.Availability.OfferBookabilityTest do
  @moduledoc """
  What a guest can book around an all-day event, and the organiser's say
  over it.

  An all-day event counts as its calendar marks it, whether or not the
  calendar takes writes: a colleague's free "WFH" day on a shared calendar
  leaves the day open. The organiser's "Treat as Busy" closes such a day and
  "Treat as Free" opens one its calendar marks busy. Checked on the booking page (`Offer.slots_for_date/3`), in the
  guest's week view (`Offer.slots_for_range/4`, which reads the calendar
  fresh), in the month view's day markers (`Offer.days_in_range/4`), in the
  calendar's bookable windows, and in the submit's own re-read
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

  # An all-day event as the sync caches it, and as the live fetch returns it
  # (`live_attrs` for where a provider presents it differently).
  defp holiday(ctx, attrs \\ %{}, live_attrs \\ %{}) do
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

    live =
      Map.merge(
        %{
          uid: row.provider_event_id,
          ical_uid: row.uid,
          summary: row.summary,
          all_day: row.all_day,
          start_time: row.start_date || row.start_at,
          end_time: row.end_date || row.end_at,
          status: "confirmed",
          transparency: row.transparency
        },
        live_attrs
      )

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

  # The month view's day markers, read from the cached booking window.
  defp month_day_open?(ctx, date) do
    request = %{profile: ctx.profile, user_timezone: ctx.profile.timezone, meeting_type: nil}

    {:ok, days} = Offer.days_in_range(request, date, Date.add(date, 6), 30)
    Map.fetch!(days, Date.to_iso8601(date))
  end

  defp probe(ctx), do: probe_at(ctx, DateTime.new!(ctx.date, ~T[11:00:00], "Etc/UTC"))

  defp probe_at(ctx, start) do
    CalendarCheck.probe(
      %{
        organizer_user_id: ctx.user.id,
        start_datetime: start,
        end_datetime: DateTime.add(start, 30, :minute)
      },
      Schedules.booking_config(ctx.user.id, nil)
    )
  end

  test "a free all-day event on a read-only calendar leaves the day open", ctx do
    holiday(ctx)

    assert "11:00 AM" in page(ctx, ctx.date)

    assert {:ok, [_window | _rest]} =
             Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)

    assert "11:00 AM" in week(ctx, ctx.date)
    assert month_day_open?(ctx, ctx.date)
    assert :ok = probe(ctx)
  end

  test "Treat as Busy closes the day on the page, the windows and the re-check", ctx do
    row = holiday(ctx)

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, true)

    assert page(ctx, ctx.date) == []
    assert "11:00 AM" in page(ctx, Date.add(ctx.date, 7))

    assert {:ok, []} =
             Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)

    assert {:error, :slot_unavailable} = probe(ctx)
  end

  test "Treat as Busy closes the day in the week view", ctx do
    row = holiday(ctx)

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, true)

    assert week(ctx, ctx.date) == []
  end

  test "Treat as Busy marks the day closed in the month view", ctx do
    row = holiday(ctx)

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, true)

    refute month_day_open?(ctx, ctx.date)
    assert month_day_open?(ctx, Date.add(ctx.date, 7))
  end

  test "clearing the override opens the day again", ctx do
    row = holiday(ctx)
    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, true)
    assert page(ctx, ctx.date) == []

    :ok = Bookability.clear(ctx.user.id, ctx.integration.id, row.uid)

    assert "11:00 AM" in page(ctx, ctx.date)
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

  test "Treat as Free frees a busy all-day event on a writable calendar", ctx do
    row = holiday(ctx, %{provider_calendar_id: "work", transparency: "opaque"})
    assert page(ctx, ctx.date) == []

    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, false)

    assert "11:00 AM" in page(ctx, ctx.date)
    assert :ok = probe(ctx)
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

  test "Treat as Busy on a calendar set not to block keeps its days open", ctx do
    row = holiday(ctx)
    :ok = Bookability.set(ctx.user.id, ctx.integration.id, row.uid, true)

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

  test "Treat as Free opens a day a feed counting every event as busy closes", ctx do
    feed =
      insert(:calendar_integration,
        user: ctx.user,
        provider: "ics_url",
        is_active: true,
        all_events_busy: true
      )

    # The feed marks the day free in the cache; the live read presents it busy.
    row =
      holiday(%{ctx | integration: feed}, %{provider: "ics_url", provider_calendar_id: "feed"}, %{
        transparency: "opaque"
      })

    assert page(ctx, ctx.date) == []

    :ok = Bookability.set(ctx.user.id, feed.id, row.uid, false)

    assert "11:00 AM" in page(ctx, ctx.date)

    assert {:ok, [_window | _rest]} =
             Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)

    assert :ok = probe(ctx)
  end

  test "Treat as Free opens a day a recurring CalDAV occurrence closes", ctx do
    caldav = insert(:calendar_integration, user: ctx.user, provider: "caldav", is_active: true)

    # The cache keys each occurrence as `<UID>_<suffix>` at the series' href;
    # the live read hands out the series' own uid and the href.
    row =
      holiday(
        %{ctx | integration: caldav},
        %{
          provider: "caldav",
          provider_calendar_id: "/calendars/work/",
          uid: "series-1_#{Date.to_iso8601(ctx.date, :basic)}",
          provider_event_id: "/calendars/work/series-1.ics",
          transparency: "opaque"
        },
        %{uid: "series-1", ical_uid: nil, href: "/calendars/work/series-1.ics"}
      )

    assert page(ctx, ctx.date) == []

    :ok = Bookability.set(ctx.user.id, caldav.id, row.uid, false)

    assert "11:00 AM" in page(ctx, ctx.date)
    assert :ok = probe(ctx)
  end

  test "an owner east of UTC: the re-check refuses the early hours of a busy day", ctx do
    %{user: user, profile: profile} =
      create_bookable_profile(timezone: "Pacific/Auckland", days: Enum.to_list(1..7))

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "holidays", "name" => "Holidays", "selected" => true, "read_only" => true}
        ]
      )

    owner = %{ctx | user: user, profile: profile, integration: integration}
    row = holiday(owner)

    # 01:00 in Auckland falls on the previous UTC date.
    start = DateTime.new!(owner.date, ~T[01:00:00], "Pacific/Auckland")

    assert Date.compare(DateTime.to_date(DateTime.shift_zone!(start, "Etc/UTC")), owner.date) ==
             :lt

    assert :ok = probe_at(owner, start)

    :ok = Bookability.set(user.id, integration.id, row.uid, true)

    assert {:error, :slot_unavailable} = probe_at(owner, start)
  end
end
