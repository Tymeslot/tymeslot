defmodule Tymeslot.Integrations.Calendar.SyncLink.RecurringSeriesTest do
  @moduledoc """
  The series master lookup: what marks a source as recurring, and the ways the
  lookup is allowed to fail.

  Under `singleEvents=true` the cached row for a recurring source is an
  *expanded instance*, and an instance carries no `recurrence` array — Google
  puts that on the master alone. So a Google row's `recurrence_rule` is not a
  description of the last occurrence; it is `nil`, always, and the field that
  marks the row as part of a series is `recurring_event_id`. Reading recurrence
  from the rule asked a question live data never answers "yes" to, so the master
  fetch below was never reached and every series mirrored as one busy block at
  the final occurrence's date.

  Every failure past that gate answers `:skip`, and that is the rest of the
  design. Skipping leaves the organiser with no placeholder, which the reconcile
  sweep retries; guessing leaves them with a wrong one, which nothing ever
  corrects.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Google.EventNormaliser
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.RecurringSeries

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")

    %{user: user, source: source}
  end

  # A cached row as Google actually produces one. `recurrence_rule` is `nil`,
  # and that is not an omission: `singleEvents=true` means Google expands the
  # series and returns instances, an instance carries no `recurrence` array —
  # only the master does — and `EventNormaliser.map_recurrence_rule/1` therefore
  # maps `nil` onto every Google row. `recurring_event_id` is the only handle an
  # instance carries back to its series, which is why it is what recurrence is
  # read from. The `resolve/2 — a Google row as the normaliser builds it`
  # describe block below builds this same shape through the real normaliser
  # rather than by hand.
  defp instance(attrs \\ %{}) do
    Map.merge(
      %ProviderCalendarEventSchema{
        uid: "series-uid@google.com",
        provider: "google",
        recurrence_rule: nil,
        recurring_event_id: "master_abc123",
        start_at: ~U[2026-09-29 09:00:00Z],
        end_at: ~U[2026-09-29 10:00:00Z]
      },
      attrs
    )
  end

  # The seam the bug lived in. `EventNormaliser` is what builds every Google
  # cache row and `RecurringSeries.resolve/2` is what reads one, but no test ever
  # drove the first into the second: the normaliser tests asserted on the struct
  # it returns and the sync-link tests invented their own, and the invented one
  # carried a `recurrence_rule` no expanded instance can have. Both suites passed
  # while every production series mirrored as a one-off block at the last
  # occurrence's date.
  #
  # The bodies here are the shapes captured off the live API, keys and all.
  describe "resolve/2 — a Google row as the normaliser builds it" do
    @normaliser_context %{
      calendar_integration_id: 42,
      provider_calendar_id: "primary",
      synced_at: ~U[2026-08-16 12:00:00Z]
    }

    # An expanded instance: `recurringEventId` present, no `recurrence` key at
    # all. This is what `singleEvents=true` returns for every occurrence of every
    # series, and it is the only shape the cache ever holds for one.
    defp normalised_instance(overrides \\ %{}) do
      raw =
        Map.merge(
          %{
            "id" => "1e683tgmubkufoa8nht2v586b5_20260703T134500Z",
            "iCalUID" => "1e683tgmubkufoa8nht2v586b5@google.com",
            "summary" => "Weekly standup",
            "status" => "confirmed",
            "transparency" => "opaque",
            "recurringEventId" => "1e683tgmubkufoa8nht2v586b5",
            "start" => %{
              "dateTime" => "2026-07-03T10:45:00-03:00",
              "timeZone" => "America/Sao_Paulo"
            },
            "end" => %{
              "dateTime" => "2026-07-03T11:30:00-03:00",
              "timeZone" => "America/Sao_Paulo"
            }
          },
          overrides
        )

      {:ok, [event]} = EventNormaliser.normalise_events([raw], @normaliser_context)
      event
    end

    test "an expanded instance carries no rule but does carry its master's id" do
      event = normalised_instance()

      # The premise the rest of this block rests on, asserted rather than
      # assumed: if Google ever started sending `recurrence` on instances, or the
      # ingest paths dropped `singleEvents=true`, this is what would say so.
      assert event.recurrence_rule == nil
      assert event.recurring_event_id == "1e683tgmubkufoa8nht2v586b5"
    end

    test "is recognised as recurring and fetches its master", %{source: source} do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
        # The id the instance pointed at, which is the only handle it has.
        assert event_id == "1e683tgmubkufoa8nht2v586b5"

        {:ok,
         %{
           "id" => "1e683tgmubkufoa8nht2v586b5",
           "recurrence" => [
             "EXDATE;TZID=America/Sao_Paulo:20260629T104500",
             "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"
           ]
         }}
      end)

      assert {:ok, series} = RecurringSeries.resolve(normalised_instance(), source)
      assert series.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"
      assert series.exceptions == ["EXDATE;TZID=America/Sao_Paulo:20260629T104500"]
    end

    test "a genuinely one-off event is not recurring and costs no request", %{source: source} do
      # No `expect`: a provider call here would fail `verify_on_exit!`. A real
      # one-off carries neither key — no `recurrence`, because it is not a
      # series, and no `recurringEventId`, because it belongs to none.
      event =
        normalised_instance(%{
          "id" => "plain0ne0ffevent",
          "iCalUID" => "plain0ne0ffevent@google.com",
          "recurringEventId" => nil
        })

      assert event.recurrence_rule == nil
      assert event.recurring_event_id == nil

      assert :not_recurring == RecurringSeries.resolve(event, source)
    end
  end

  describe "resolve/2 — a non-recurring source" do
    test "is not a series and costs no request", %{source: source} do
      # No `expect` at all: a provider call here would fail `verify_on_exit!`.
      #
      # Both keys are absent, which is what makes this a one-off. The earlier
      # version of this test cleared only `recurrence_rule` and left the master
      # id in place, and so asserted that the shape of *every production row* was
      # not recurring — pinning the bug as the specification.
      assert :not_recurring ==
               RecurringSeries.resolve(
                 instance(%{recurrence_rule: nil, recurring_event_id: nil}),
                 source
               )
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

      # The cached instance has no rule of its own to fall back to — it is an
      # expanded occurrence — so the whole rule can only have come from the
      # master that was fetched.
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

  describe "resolve/2 — the mandatory skips" do
    test "a row with a rule but no master id is not mirrored from that rule", %{source: source} do
      # No expectation: nothing to fetch the master with, so no request may be
      # made. The cached rule is right there and must not be used.
      #
      # This is the shape a *non-Google* ingest leaves behind — Outlook and the
      # CalDAV family cache a real series rule — and the shape a Google row would
      # have had before `singleEvents=true`. It reaches `:not_recurring` rather
      # than `{:skip, :no_series_master}` because recurrence is read from the
      # master id, and the outcome is the same either way: no placeholder built
      # from the row's own rule. Which of the two it is matters to the caller
      # only in that a skip is logged and a not-recurring is not, and a source
      # that cannot name a master is not a series this module can describe.
      assert :not_recurring ==
               RecurringSeries.resolve(
                 instance(%{
                   recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
                   recurring_event_id: nil
                 }),
                 source
               )
    end

    test "an empty master id is no handle at all, and skips", %{source: source} do
      # No expectation, for the same reason. `""` is a value the column permits
      # and no provider means, so it is refused at both gates: it is not a series
      # to resolve, and it is not an id to fetch with.
      assert :not_recurring ==
               RecurringSeries.resolve(instance(%{recurring_event_id: ""}), source)
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
