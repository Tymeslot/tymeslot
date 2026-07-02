defmodule Tymeslot.AgendaTest do
  @moduledoc """
  Tests for the dashboard agenda: merging bookings with synced calendar events,
  deduplication, filtering, timezone bucketing, and the hero fallback.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :calendar

  alias Tymeslot.Agenda
  alias Tymeslot.Agenda.Day
  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Utils.DateTimeUtils

  setup do
    today = Date.utc_today()
    {:ok, user: insert(:user), today: today, tomorrow: Date.add(today, 1)}
  end

  describe "day_agenda/2 merging" do
    test "merges confirmed bookings and synced calendar events", %{user: user, tomorrow: tomorrow} do
      booking(user, at(tomorrow, ~T[12:00:00]), title: "Client call")
      external_event(user, at(tomorrow, ~T[13:00:00]), summary: "Team sync")

      day = Agenda.day_agenda(user, "Etc/UTC")

      assert day.has_calendar?
      assert "Client call" in titles(day)
      assert "Team sync" in titles(day)
    end

    test "tags each entry with the calendar it belongs to", %{user: user, tomorrow: tomorrow} do
      booking(user, at(tomorrow, ~T[12:00:00]), title: "Client call")

      integration = insert(:calendar_integration, user: user, name: "Work Google")

      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Team sync",
        start_at: at(tomorrow, ~T[13:00:00]),
        end_at: at(tomorrow, ~T[14:00:00]),
        all_day: false
      )

      day = Agenda.day_agenda(user, "Etc/UTC")

      booking = Enum.find(entries(day), &(&1.title == "Client call"))
      synced = Enum.find(entries(day), &(&1.title == "Team sync"))

      # A booking is a Tymeslot entry (no synced calendar); a synced event carries
      # the integration's name so the UI can say which calendar it came from.
      assert booking.calendar == nil
      assert synced.calendar == "Work Google"
    end

    test "surfaces the earliest timed entry as the hero and excludes it from the groups",
         %{user: user, tomorrow: tomorrow} do
      booking(user, at(tomorrow, ~T[14:00:00]), title: "Later")
      booking(user, at(tomorrow, ~T[12:00:00]), title: "Sooner")

      day = Agenda.day_agenda(user, "Etc/UTC")

      assert day.next.title == "Sooner"
      assert Enum.map(day.tomorrow, & &1.title) == ["Later"]
      refute "Sooner" in Enum.map(day.tomorrow, & &1.title)
    end
  end

  describe "day_agenda/2 deduplication and filtering" do
    test "drops external events that are our own synced bookings", %{
      user: user,
      tomorrow: tomorrow
    } do
      external_event(user, at(tomorrow, ~T[12:00:00]),
        summary: "Synced copy",
        created_by_tymeslot: true
      )

      assert Day.empty?(Agenda.day_agenda(user, "Etc/UTC"))
    end

    test "drops external events matching a booking's provider_event_id",
         %{user: user, tomorrow: tomorrow} do
      slot = at(tomorrow, ~T[12:00:00])
      booking(user, slot, title: "Real booking", provider_event_id: "evt-123")
      external_event(user, slot, summary: "Duplicate", provider_event_id: "evt-123")

      day = Agenda.day_agenda(user, "Etc/UTC")

      assert [entry] = entries(day)
      assert entry.title == "Real booking"
      assert entry.source == :tymeslot
    end

    test "excludes transparent (free) external events", %{user: user, tomorrow: tomorrow} do
      external_event(user, at(tomorrow, ~T[12:00:00]),
        summary: "Focus time",
        transparency: "transparent"
      )

      assert Day.empty?(Agenda.day_agenda(user, "Etc/UTC"))
    end

    test "excludes cancelled external events", %{user: user, tomorrow: tomorrow} do
      external_event(user, at(tomorrow, ~T[12:00:00]), summary: "Called off", status: "cancelled")

      assert Day.empty?(Agenda.day_agenda(user, "Etc/UTC"))
    end

    test "excludes pending and cancelled bookings", %{user: user, tomorrow: tomorrow} do
      booking(user, at(tomorrow, ~T[12:00:00]), title: "Pending", status: "pending")
      booking(user, at(tomorrow, ~T[13:00:00]), title: "Cancelled", status: "cancelled")

      assert Day.empty?(Agenda.day_agenda(user, "Etc/UTC"))
    end
  end

  describe "day_agenda/2 all-day events" do
    test "places all-day events in their day group and never as the hero",
         %{user: user, tomorrow: tomorrow} do
      booking(user, at(tomorrow, ~T[12:00:00]), title: "Timed")
      all_day_event(user, tomorrow, summary: "Company offsite")

      day = Agenda.day_agenda(user, "Etc/UTC")

      assert day.next.title == "Timed"
      assert offsite = Enum.find(day.tomorrow, &(&1.title == "Company offsite"))
      assert offsite.all_day?
    end
  end

  describe "day_agenda/2 calendar presence and hero fallback" do
    test "works without any calendar integration", %{user: user, tomorrow: tomorrow} do
      booking(user, at(tomorrow, ~T[12:00:00]), title: "Solo booking")

      day = Agenda.day_agenda(user, "Etc/UTC")

      refute day.has_calendar?
      assert "Solo booking" in titles(day)
    end

    test "keeps the hero populated with the next appointment beyond tomorrow",
         %{user: user, today: today} do
      booking(user, at(Date.add(today, 5), ~T[12:00:00]), title: "Next week")

      day = Agenda.day_agenda(user, "Etc/UTC")

      assert day.next.title == "Next week"
      assert day.later?
      assert day.today == []
      assert day.tomorrow == []
    end

    test "is empty when nothing is upcoming", %{user: user} do
      assert Day.empty?(Agenda.day_agenda(user, "Etc/UTC"))
    end
  end

  describe "day_agenda/2 timezone bucketing" do
    test "buckets entries by the user's timezone", %{user: user, tomorrow: tomorrow} do
      # Late-evening UTC lands on a different calendar day in a far-ahead zone.
      start = at(tomorrow, ~T[23:30:00])
      booking(user, start, title: "Edge of day")

      expected_utc = local_date(start, "Etc/UTC")
      expected_ahead = local_date(start, "Pacific/Kiritimati")

      assert Agenda.day_agenda(user, "Etc/UTC").next.day == expected_utc
      assert Agenda.day_agenda(user, "Pacific/Kiritimati").next.day == expected_ahead
      refute expected_utc == expected_ahead
    end

    test "falls back to UTC for a blank timezone", %{user: user, tomorrow: tomorrow} do
      booking(user, at(tomorrow, ~T[12:00:00]), title: "Whenever")

      assert Agenda.day_agenda(user, nil).timezone == "Etc/UTC"
      assert Agenda.day_agenda(user, "").timezone == "Etc/UTC"
    end
  end

  describe "day_agenda/2 multi-day and in-progress overlap" do
    test "keeps a multi-day all-day event on every day it spans", %{
      user: user,
      today: today
    } do
      # A block that started yesterday and runs for several days — a week of leave.
      multi_day_all_day_event(user, Date.add(today, -1), Date.add(today, 3), summary: "On leave")

      day = Agenda.day_agenda(user, "Etc/UTC")

      assert Enum.any?(day.today, &(&1.title == "On leave"))
      assert Enum.any?(day.tomorrow, &(&1.title == "On leave"))
    end
  end

  describe "Entry.covers?/3" do
    test "a same-day timed entry covers only its day" do
      entry = timed_entry(~D[2026-07-02], ~U[2026-07-02 11:00:00Z])

      assert Entry.covers?(entry, ~D[2026-07-02], "Etc/UTC")
      refute Entry.covers?(entry, ~D[2026-07-03], "Etc/UTC")
      refute Entry.covers?(entry, ~D[2026-07-01], "Etc/UTC")
    end

    test "an overnight timed entry covers the day it started and the next" do
      entry = timed_entry(~D[2026-07-02], ~U[2026-07-03 01:00:00Z])

      assert Entry.covers?(entry, ~D[2026-07-02], "Etc/UTC")
      assert Entry.covers?(entry, ~D[2026-07-03], "Etc/UTC")
      refute Entry.covers?(entry, ~D[2026-07-04], "Etc/UTC")
    end

    test "a multi-day all-day entry covers each day in [start, end), end exclusive" do
      # start_date 2 Jul, end_date 5 Jul → end_at is local midnight of 5 Jul.
      entry = all_day_entry(~D[2026-07-02], ~U[2026-07-05 00:00:00Z])

      assert Entry.covers?(entry, ~D[2026-07-02], "Etc/UTC")
      assert Entry.covers?(entry, ~D[2026-07-04], "Etc/UTC")
      refute Entry.covers?(entry, ~D[2026-07-05], "Etc/UTC")
      refute Entry.covers?(entry, ~D[2026-07-01], "Etc/UTC")
    end
  end

  # --- Helpers ---------------------------------------------------------------

  defp booking(user, start, opts) do
    {status, opts} = Keyword.pop(opts, :status, "confirmed")

    insert(
      :meeting,
      [
        organizer_email: user.email,
        start_time: start,
        end_time: DateTime.add(start, 3600, :second),
        status: status
      ] ++ opts
    )
  end

  defp external_event(user, start, opts) do
    integration = insert(:calendar_integration, user: user)

    insert(
      :provider_calendar_event,
      [
        calendar_integration: integration,
        start_at: start,
        end_at: DateTime.add(start, 3600, :second),
        all_day: false
      ] ++ opts
    )
  end

  defp all_day_event(user, date, opts) do
    integration = insert(:calendar_integration, user: user)

    insert(
      :provider_calendar_event,
      [
        calendar_integration: integration,
        all_day: true,
        start_date: date,
        end_date: Date.add(date, 1),
        start_at: nil,
        end_at: nil
      ] ++ opts
    )
  end

  defp multi_day_all_day_event(user, start_date, end_date, opts) do
    integration = insert(:calendar_integration, user: user)

    insert(
      :provider_calendar_event,
      [
        calendar_integration: integration,
        all_day: true,
        start_date: start_date,
        end_date: end_date,
        start_at: nil,
        end_at: nil
      ] ++ opts
    )
  end

  defp timed_entry(day, end_at) do
    %Entry{
      id: "t",
      source: :external,
      title: "t",
      day: day,
      start_at: DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
      end_at: end_at,
      all_day?: false
    }
  end

  defp all_day_entry(start_date, end_at) do
    %Entry{
      id: "a",
      source: :external,
      title: "a",
      day: start_date,
      start_at: DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
      end_at: end_at,
      all_day?: true
    }
  end

  defp at(date, time), do: DateTime.new!(date, time, "Etc/UTC")

  defp local_date(datetime, tz),
    do: datetime |> DateTimeUtils.convert_to_timezone(tz) |> DateTime.to_date()

  defp entries(%Day{} = day),
    do: Enum.reject([day.next | day.today ++ day.tomorrow], &is_nil/1)

  defp titles(day), do: day |> entries() |> Enum.map(& &1.title)
end
