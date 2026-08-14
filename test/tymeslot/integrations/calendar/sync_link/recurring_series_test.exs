defmodule Tymeslot.Integrations.Calendar.SyncLink.RecurringSeriesTest do
  @moduledoc """
  The series master lookup, and the two ways it is allowed to fail.

  Both failures answer `:skip`, and that is the whole point of this module.
  Under `singleEvents=true` the cached row for a recurring source is an
  *expanded instance* whose `recurrence_rule` describes whatever the last
  occurrence carried — so the tempting fallback, "use the rule we already have",
  places a single busy block at the final occurrence's date. Skipping leaves the
  organiser with no placeholder, which the reconcile sweep retries; guessing
  leaves them with a wrong one, which nothing ever corrects.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.RecurringSeries

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")

    %{user: user, source: source}
  end

  defp instance(attrs \\ %{}) do
    Map.merge(
      %ProviderCalendarEventSchema{
        uid: "series-uid@google.com",
        provider: "google",
        recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
        recurring_event_id: "master_abc123",
        start_at: ~U[2026-09-29 09:00:00Z],
        end_at: ~U[2026-09-29 10:00:00Z]
      },
      attrs
    )
  end

  describe "resolve/2 — a non-recurring source" do
    test "is not a series and costs no request", %{source: source} do
      # No `expect` at all: a provider call here would fail `verify_on_exit!`.
      assert :not_recurring ==
               RecurringSeries.resolve(instance(%{recurrence_rule: nil}), source)
    end
  end

  describe "resolve/2 — the master's rule" do
    test "returns the master's RRULE, not the cached instance's", %{source: source} do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
        assert event_id == "master_abc123"

        {:ok,
         %{
           "id" => "master_abc123",
           "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=12"]
         }}
      end)

      # The cached instance claims a bare weekly rule; the master carries the
      # COUNT. Asserting on the difference is what proves the master was read
      # rather than the row that was already in hand.
      assert {:ok, series} = RecurringSeries.resolve(instance(), source)
      assert series.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=12"
    end

    test "reads the RRULE from anywhere in the recurrence list", %{source: source} do
      # Google returns `recurrence` as a list whose entries may be RRULE,
      # EXDATE, RDATE or EXRULE in any order. The normaliser keeps only the
      # first, which is why this module reads the raw list itself.
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok,
         %{
           "recurrence" => [
             "EXDATE;TZID=Europe/Tallinn:20261013T090000",
             "RRULE:FREQ=WEEKLY;BYDAY=TU"
           ]
         }}
      end)

      assert {:ok, series} = RecurringSeries.resolve(instance(), source)
      assert series.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"
    end

    test "a master carrying no RRULE at all is a skip, not an empty rule", %{source: source} do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok, %{"id" => "master_abc123", "summary" => "Not actually a series"}}
      end)

      assert {:skip, :master_has_no_recurrence_rule} ==
               RecurringSeries.resolve(instance(), source)
    end
  end

  describe "resolve/2 — exceptions" do
    test "reports the master's EXDATEs alongside the rule", %{source: source} do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok,
         %{
           "recurrence" => [
             "RRULE:FREQ=WEEKLY;BYDAY=TU",
             "EXDATE;TZID=Europe/Tallinn:20261013T090000",
             "EXDATE;TZID=Europe/Tallinn:20261020T090000"
           ]
         }}
      end)

      assert {:ok, series} = RecurringSeries.resolve(instance(), source)
      assert series.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"

      assert series.exceptions == [
               "EXDATE;TZID=Europe/Tallinn:20261013T090000",
               "EXDATE;TZID=Europe/Tallinn:20261020T090000"
             ]
    end

    test "a series with no exceptions reports an empty list", %{source: source} do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok, %{"recurrence" => ["RRULE:FREQ=DAILY;COUNT=5"]}}
      end)

      assert {:ok, series} = RecurringSeries.resolve(instance(), source)
      assert series.exceptions == []
    end
  end

  describe "resolve/2 — the two mandatory skips" do
    test "a recurring instance with no recurring_event_id skips rather than guessing", %{
      source: source
    } do
      # No expectation: nothing to fetch the master with, so no request may be
      # made. The cached rule is right there and must not be used — it is the
      # last occurrence's, and mirroring it is the bug this stage exists to
      # prevent.
      assert {:skip, :no_series_master} ==
               RecurringSeries.resolve(instance(%{recurring_event_id: nil}), source)
    end

    test "a failed master fetch skips and leaves the retry to the sweep", %{source: source} do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:error, :rate_limited, "Rate limited"}
      end)

      assert {:skip, :master_fetch_failed} == RecurringSeries.resolve(instance(), source)
    end

    test "a master that has been deleted skips too", %{source: source} do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:error, :not_found, "Event not found"}
      end)

      assert {:skip, :master_fetch_failed} == RecurringSeries.resolve(instance(), source)
    end
  end

  describe "resolve/2 — providers without a master lookup" do
    test "a non-Google source skips: there is no single-event GET to read", %{user: user} do
      outlook = insert(:calendar_integration, user: user, provider: "outlook")

      assert {:skip, :provider_has_no_series_lookup} ==
               RecurringSeries.resolve(instance(%{provider: "outlook"}), outlook)
    end
  end

  describe "resolve/2 — which calendar is asked" do
    # The master lives on the same calendar as its instances, and the row
    # records which that was. An organiser with several Google calendars
    # connected through one integration has instances from all of them cached
    # under the same row shape, so asking the integration's default would look
    # for the master on the wrong calendar and 404.
    test "asks the calendar the instance was synced from", %{user: user} do
      source =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          default_booking_calendar_id: "bookings@group.calendar.google.com"
        )

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, _event_id ->
        assert calendar_id == "team@group.calendar.google.com"
        {:ok, %{"recurrence" => ["RRULE:FREQ=WEEKLY"]}}
      end)

      assert {:ok, _series} =
               RecurringSeries.resolve(
                 instance(%{provider_calendar_id: "team@group.calendar.google.com"}),
                 source
               )
    end

    test "falls back to the integration's booking calendar, then to primary", %{user: user} do
      booking =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          default_booking_calendar_id: "bookings@group.calendar.google.com"
        )

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, _event_id ->
        assert calendar_id == "bookings@group.calendar.google.com"
        {:ok, %{"recurrence" => ["RRULE:FREQ=WEEKLY"]}}
      end)

      assert {:ok, _series} = RecurringSeries.resolve(instance(), booking)

      plain = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, calendar_id, _event_id ->
        assert calendar_id == "primary"
        {:ok, %{"recurrence" => ["RRULE:FREQ=WEEKLY"]}}
      end)

      assert {:ok, _series} = RecurringSeries.resolve(instance(), plain)
    end
  end
end
