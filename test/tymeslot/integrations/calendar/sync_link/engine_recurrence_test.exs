defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineRecurrenceTest do
  @moduledoc """
  A recurring source becomes one recurring placeholder, or none at all.

  The assertions that earn their keep are the ones on the *payload handed to the
  provider*, not on the stored mirror row. A mirror row proves only that
  Tymeslot recorded a write; it says nothing about whether the RRULE reached the
  target, and a version that stored the row correctly while sending a payload
  with no `recurrence_rule` would write a single busy block at the last
  occurrence's date and pass a row-only test. That is precisely the failure this
  stage exists to remove, so the payload is what gets asserted.

  The request-count test is the second: one master fetch per series per change.
  A version that fetched per occurrence would be correct and unaffordable, and
  nothing but counting the calls tells the two apart.

  The EXDATE tests are the third, and are on the payload for the same reason. A
  cancelled occurrence is freed by the `EXDATE` line reaching the target, not by
  anything Tymeslot stores: a version that resolved the exceptions correctly and
  dropped them on the way into the payload would leave the cancelled Tuesday
  blocked and pass every row-level assertion.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    context = linked_pair()

    # Reloaded through the query module so `source_integration` is preloaded, as
    # it is for every production caller. The master fetch needs the source
    # integration's token, and a link built straight from the factory carries an
    # unloaded association — which the engine skips on rather than raising, but
    # which would make every assertion here about the wrong thing.
    {:ok, link} = CalendarSyncLinkQueries.get(context.link.id)

    %{context | link: link}
  end

  # A weekly series as the cache actually holds it: one row, carrying the LAST
  # occurrence's times, because `upsert_batch/1` keeps the last of the expanded
  # instances. Those times are the values a naive implementation would mirror,
  # and they are wrong for the series.
  #
  # `recurrence_rule` is `nil`, which is the row's real shape: only the master
  # carries a `recurrence` array, so no Google row in the cache has a rule and
  # `recurring_event_id` is the only mark of a series. An earlier fixture set
  # both, a combination no Google row can have, and that is what let a version
  # gating recurrence on the rule pass every test here while mirroring every
  # series wrongly in production.
  defp weekly_instance(source, attrs \\ %{}) do
    Map.merge(
      %ProviderCalendarEventSchema{
        uid: "weekly-series@google.com",
        calendar_integration_id: source.id,
        provider: "google",
        provider_calendar_id: "primary",
        provider_event_id: "master_abc123_20261215T090000Z",
        summary: "Weekly standup",
        transparency: "opaque",
        status: "confirmed",
        all_day: false,
        # December: the final occurrence, months after the series began.
        start_at: ~U[2026-12-15 09:00:00Z],
        end_at: ~U[2026-12-15 09:30:00Z],
        recurrence_rule: nil,
        recurring_event_id: "master_abc123"
      },
      attrs
    )
  end

  # The master's own start is March, the series' first occurrence. Every cached
  # instance the engine ever sees is later than this — that gap is the whole
  # point of fetching the master, so the fixture carries it.
  @master_start "2026-03-03T09:00:00Z"
  @master_end "2026-03-03T09:30:00Z"

  defp expect_master(recurrence, times \\ 1) do
    expect(GoogleCalendarAPIMock, :get_event, times, fn _integration, _calendar_id, event_id ->
      assert event_id == "master_abc123"

      {:ok,
       %{
         "id" => "master_abc123",
         "recurrence" => recurrence,
         "start" => %{"dateTime" => @master_start},
         "end" => %{"dateTime" => @master_end}
       }}
    end)
  end

  describe "a weekly Google source onto a Google target" do
    test "sends one placeholder carrying the master's RRULE, and records one mirror", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261215T090000Z"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}

      # The master's rule, not the cached instance's bare `FREQ=WEEKLY;BYDAY=TU`.
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261215T090000Z"

      # Still a placeholder in every other respect: the tier's title, opaque so
      # it actually blocks, and no attendees at any tier.
      assert payload.summary == "Busy"
      assert payload.transparency == :opaque
      refute Map.has_key?(payload, :attendees)

      # ONE mirror row for the whole series — the target expands it.
      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(
                 link.id,
                 "weekly-series@google.com"
               )

      assert mirror.target_uid == Engine.target_uid_for(link.id, "weekly-series@google.com")
      assert [_only_one] = CalendarSyncMirrorQueries.list_for_link(link.id)
    end

    test "the placeholder starts where the series starts, not where the cached row does", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      instance = weekly_instance(source)
      assert :ok == Engine.mirror(link, instance, user.id)

      assert_received {:payload, payload}

      # A DTSTART taken from the cached row would be December — `singleEvents`
      # expands the series and `upsert_batch/1` keeps the last instance, so the
      # row is the *final* occurrence. Pairing that with the master's rule
      # describes "every Tuesday from December onwards, forever": every real
      # occurrence before then goes unblocked, and every date after the series
      # ends is blocked permanently. The rule and the start have to come from
      # the same place, and that place is the master.
      assert payload.start_time == ~U[2026-03-03 09:00:00Z]
      assert payload.end_time == ~U[2026-03-03 09:30:00Z]

      refute payload.start_time == instance.start_at
    end

    test "an all-day series starts on the master's date", %{
      user: user,
      source: source,
      link: link
    } do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok,
         %{
           "id" => "master_abc123",
           "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=TU"],
           "start" => %{"date" => "2026-03-03"},
           "end" => %{"date" => "2026-03-04"}
         }}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      instance =
        weekly_instance(source, %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-12-15],
          end_date: ~D[2026-12-16]
        })

      assert :ok == Engine.mirror(link, instance, user.id)

      assert_received {:payload, payload}

      # The all-day branch has to follow the master too, and has to keep
      # emitting `Date` values: every outbound mapper reads the *type* to decide
      # whether it is writing an all-day event.
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-03-03]
      assert payload.end_time == ~D[2026-03-04]
    end

    test "a full_passthrough link still carries the rule, and still no attendees", %{
      user: user,
      source: source,
      link: link
    } do
      {:ok, link} =
        CalendarSyncLinkQueries.update(link, %{privacy_tier: "full_passthrough"})

      {:ok, link} = CalendarSyncLinkQueries.get(link.id)

      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}
      assert payload.summary == "Weekly standup"
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"
      refute Map.has_key?(payload, :attendees)
    end

    test "a private source degrades to Busy and keeps the rule", %{
      user: user,
      source: source,
      link: link
    } do
      {:ok, link} = CalendarSyncLinkQueries.update(link, %{privacy_tier: "full_passthrough"})
      {:ok, link} = CalendarSyncLinkQueries.get(link.id)

      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      instance = weekly_instance(source, %{visibility: "private"})
      assert :ok == Engine.mirror(link, instance, user.id)

      assert_received {:payload, payload}
      assert payload.summary == "Busy"
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"
    end
  end

  describe "the master fetch costs one request per series per change" do
    test "one create writes one placeholder from one master fetch", %{
      user: user,
      source: source,
      link: link
    } do
      # `expect/4` with a count of 1 fails on a second call, and
      # `verify_on_exit!` fails on none — so this asserts exactly one fetch
      # whichever way an implementation went wrong. A per-occurrence version
      # would call it once per expanded instance.
      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU"], 1)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)
    end

    test "a subsequent update fetches the master once more, not once per occurrence", %{
      user: user,
      source: source,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "weekly-series@google.com")

      mirror_for_link(link,
        source_uid: "weekly-series@google.com",
        target_uid: target_uid,
        target_provider_event_id: "target-pid-1"
      )

      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=20"], 1)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        send(test_pid, {:payload, event_data})
        :ok
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=20"
    end

    test "a non-recurring source costs no master fetch at all", %{
      user: user,
      source: source,
      link: link
    } do
      # No `expect` for `get_event` — a call would fail the Mox verification.
      #
      # A genuine one-off: no master id, which is what distinguishes it from a
      # series row. Both Google shapes have a `nil` rule, so the rule is not what
      # tells them apart and clearing it alone would not have made this ordinary.
      ordinary =
        weekly_instance(source, %{
          uid: "one-off@google.com",
          recurring_event_id: nil
        })

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, ordinary, user.id)

      assert_received {:payload, payload}
      refute Map.has_key?(payload, :recurrence_rule)
    end
  end

  describe "a series the master cannot describe is skipped, never guessed" do
    test "a cached rule with no master id never reaches the payload", %{
      user: user,
      source: source,
      link: link
    } do
      # No `get_event` expectation: there is no id to fetch a master with, so no
      # request may be made.
      #
      # The row carries a rule anyway — the shape a non-Google ingest leaves, or
      # a Google row from before `singleEvents=true`. That rule is the one thing
      # that must not travel: it describes the last occurrence, and a placeholder
      # built from it blocks a single wrong date forever while looking correct.
      # So the event is mirrored as what it can be shown to be, a one-off at its
      # own time, and the payload carries no rule at all.
      instance =
        weekly_instance(source, %{
          recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
          recurring_event_id: nil
        })

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, instance, user.id)

      assert_received {:payload, payload}
      refute Map.has_key?(payload, :recurrence_rule)
    end

    test "a failed master fetch writes nothing and leaves the retry to the sweep", %{
      user: user,
      source: source,
      link: link
    } do
      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:error, :rate_limited, "Rate limited"}
      end)

      assert {:discard, :series_master_unavailable} ==
               Engine.mirror(link, weekly_instance(source), user.id)

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(
                 link.id,
                 "weekly-series@google.com"
               )
    end

    test "an existing placeholder is left alone rather than overwritten with a guess", %{
      user: user,
      source: source,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "weekly-series@google.com")

      mirror_for_link(link,
        source_uid: "weekly-series@google.com",
        target_uid: target_uid,
        target_provider_event_id: "target-pid-1"
      )

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:error, :rate_limited, "Rate limited"}
      end)

      # No `update_event` expectation: the correct placeholder that is already
      # there must not be replaced by one built from the instance's rule.
      assert {:discard, :series_master_unavailable} ==
               Engine.mirror(link, weekly_instance(source), user.id)

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(
                 link.id,
                 "weekly-series@google.com"
               )

      assert mirror.target_provider_event_id == "target-pid-1"
    end
  end

  describe "a cancelled occurrence stops blocking time" do
    test "the master's EXDATE lines reach the payload alongside the rule", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000"
      ])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      # The rule alone would keep blocking the cancelled Tuesday. The EXDATE is
      # what frees it, so it is what gets asserted on the payload the provider
      # was handed — the placeholder's own row proves nothing about this.
      assert_received {:payload, payload}
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20261013T090000"
             ]
    end

    test "every EXDATE line the master carries travels, in order", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000",
        "EXDATE;TZID=Europe/Tallinn:20261020T090000"
      ])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20261013T090000",
               "EXDATE;TZID=Europe/Tallinn:20261020T090000"
             ]
    end

    test "an occurrence cancelled between passes reaches the update too", %{
      user: user,
      source: source,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "weekly-series@google.com")

      mirror_for_link(link,
        source_uid: "weekly-series@google.com",
        target_uid: target_uid,
        target_provider_event_id: "target-pid-1"
      )

      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000"
      ])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, event_data, _context ->
        send(test_pid, {:payload, event_data})
        :ok
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20261013T090000"
             ]
    end

    test "a series with no exceptions carries no exception key at all", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"
      refute Map.has_key?(payload, :recurrence_exception_lines)
    end

    # RDATE and EXRULE lines a master may also carry are not exceptions and are
    # not forwarded. `RecurringSeries` filters to EXDATE alone, and this pins
    # that the payload does not quietly widen to whatever the master held.
    test "only EXDATE lines travel; other recurrence lines do not", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "RDATE;TZID=Europe/Tallinn:20261110T090000",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000"
      ])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert_received {:payload, payload}

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20261013T090000"
             ]
    end
  end

  describe "deleting the source" do
    test "removes the single placeholder that stood for the whole series", %{
      user: user,
      source: _source,
      link: link
    } do
      target_uid = Engine.target_uid_for(link.id, "weekly-series@google.com")

      mirror_for_link(link,
        source_uid: "weekly-series@google.com",
        target_uid: target_uid,
        target_provider_event_id: "target-pid-1"
      )

      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
        send(test_pid, {:deleted, uid})
        :ok
      end)

      # No master fetch: a withdrawal needs no rule, and paying for one to
      # delete a block would be a request per teardown for nothing.
      assert :ok == Engine.unmirror(link, "weekly-series@google.com", user.id)

      assert_received {:deleted, deleted_uid}
      assert deleted_uid == target_uid

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(
                 link.id,
                 "weekly-series@google.com"
               )

      assert [] == CalendarSyncMirrorQueries.list_for_link(link.id)
    end
  end

  describe "the series master is fetched once, not once per link" do
    test "two links onto the same series share one master fetch", ctx do
      %{user: user, source: source, link: first} = ctx
      {_second_target, built} = extra_target_link(ctx)

      # Reloaded for the same reason the setup reloads the first: the master
      # fetch needs the source integration, and a factory-built link carries an
      # unloaded association the engine skips on.
      {:ok, second} = CalendarSyncLinkQueries.get(built.id)

      # One expectation, so a second call fails the test through Mox. The
      # fan-out is per link — the sync path enqueues a job each — and the master
      # is identical for both: a calendar with fifty series on three links would
      # otherwise ask for a hundred and fifty masters where fifty exist, every
      # sweep, against the quota the user-facing paths share.
      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU"])

      expect(Tymeslot.CalendarMock, :create_event, 2, fn _event_data, _context ->
        {:ok, %{provider_event_id: "target-pid"}}
      end)

      instance = weekly_instance(source)

      assert :ok == Engine.mirror(first, instance, user.id)
      assert :ok == Engine.mirror(second, instance, user.id)

      # Both links still got their own placeholder; only the read was shared.
      assert [_one] = CalendarSyncMirrorQueries.list_for_link(first.id)
      assert [_two] = CalendarSyncMirrorQueries.list_for_link(second.id)
    end
  end
end
