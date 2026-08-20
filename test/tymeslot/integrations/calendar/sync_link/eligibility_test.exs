defmodule Tymeslot.Integrations.Calendar.SyncLink.EligibilityTest do
  @moduledoc """
  The single loop-prevention rule, pinned.

  The rule that matters most here is the first one: a cached event whose
  `{integration_id, uid}` is already in the mirror set is a leaf and must never
  spawn a mirror of its own. Everything else in this module — recurrence,
  transparency, cancellation — is a scoping rule that can be relaxed later; that
  one is what stops two linked calendars writing placeholders at each other
  forever.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility

  @integration_id 42

  defp event(attrs) do
    defaults = %{
      uid: "source-uid",
      calendar_integration_id: @integration_id,
      provider: :google,
      provider_calendar_id: "primary",
      provider_event_id: "pid-1",
      all_day: false,
      start_at: ~U[2026-07-03 10:00:00Z],
      end_at: ~U[2026-07-03 11:00:00Z],
      synced_at: ~U[2026-07-01 00:00:00Z]
    }

    CalendarEvent.new!(Map.merge(defaults, Map.new(attrs)))
  end

  describe "mirror_source?/2 — loop prevention" do
    test "an ordinary event on a source calendar is an eligible source" do
      assert Eligibility.mirror_source?(event([]), MapSet.new())
    end

    test "an event already recorded as a mirror is never a source again" do
      mirrors = MapSet.new([{@integration_id, "source-uid"}])

      refute Eligibility.mirror_source?(event([]), mirrors)
    end

    test "the mirror set is keyed on integration as well as UID" do
      mirrors = MapSet.new([{@integration_id + 1, "source-uid"}])

      assert Eligibility.mirror_source?(event([]), mirrors),
             "a mirror living on a different integration must not disqualify this event"
    end

    # The keying above is deliberate, and it is also the whole reason the caller
    # has to hand this function the right set. A placeholder does not always sit
    # on the calendar it was written for: when a link's target loses its
    # authorisation, `BookingIntegrationResolver` substitutes the organiser's
    # primary calendar and the placeholder lands on the link's *source*.
    #
    # Keyed on the mirror's target it matched nothing here, so the source's own
    # sync read it as an ordinary event and mirrored it again — one real event
    # grew copies three generations deep inside two minutes on a live calendar.
    #
    # This function is not the place that fixes it; `Sync.filter_mirrorable/2`
    # is, by asking `mirror_uids_for_sync/1` for a link-scoped set. What is
    # pinned here is the contract that makes that possible: given a set that
    # *does* name the calendar the event was found on, the event is refused.
    # Stated as its own test because every other case in this file builds both
    # sides from `@integration_id`, so a mismatch could not be expressed at all.
    test "a placeholder found on a calendar other than its target is still refused" do
      placeholder_on_the_source = event(uid: "tymeslot-mirror-abc")

      link_scoped_set = MapSet.new([{@integration_id, "tymeslot-mirror-abc"}])

      refute Eligibility.mirror_source?(placeholder_on_the_source, link_scoped_set),
             "a set naming the calendar the placeholder was found on must refuse it, " <>
               "whichever calendar it was originally written for"
    end

    test "a placeholder stays a leaf however many calendars mirror into its own" do
      # The link matrix lets one calendar receive from every other, so a
      # calendar can hold placeholders originating from four sources at once.
      # The rule is a membership test on `{integration_id, uid}` and carries no
      # notion of how many links exist, but the fan-out case is what the grid
      # makes easy to build and a regression here is unbounded rather than
      # cosmetic: a placeholder that mirrored onward would generate events
      # until a provider quota stopped it.
      mirrors =
        MapSet.new(for source <- 1..4, do: {@integration_id, "from-calendar-#{source}"})

      for source <- 1..4 do
        refute Eligibility.mirror_source?(event(uid: "from-calendar-#{source}"), mirrors),
               "a placeholder from calendar #{source} must not mirror onward"
      end

      # An organiser's own event on that same crowded calendar still mirrors
      # out — the fan-in must not disable the calendar as a source.
      assert Eligibility.mirror_source?(event(uid: "my-own-meeting"), mirrors)
    end
  end

  describe "mirror_source?/3 — scoping rules" do
    test "a transparent event is skipped: it does not consume the owner's time" do
      refute Eligibility.mirror_source?(event(transparency: :transparent), MapSet.new())
    end

    test "a cancelled event is skipped" do
      refute Eligibility.mirror_source?(event(status: :cancelled), MapSet.new())
    end

    test "a declined event is skipped" do
      refute Eligibility.mirror_source?(event(status: :declined), MapSet.new())
    end

    test "a tentative event still blocks time and is an eligible source" do
      assert Eligibility.mirror_source?(event(status: :tentative), MapSet.new())
    end
  end

  # The mark a recurring source actually carries. `singleEvents=true` returns
  # expanded instances, and an instance carries no `recurrence` array — only the
  # master does — so `recurrence_rule` is nil on every Google row and
  # `recurring_event_id` is the only sign of a series.
  #
  # This is the default here because the clause it exercises,
  # `recurring?(%{recurring_event_id: id})`, is the one that fires on real
  # traffic. The coverage used to run the other way: nine tests marked recurrence
  # with a bare rule and one with the master id, so the clause that never fires
  # in production was pinned nine times over and the clause that always fires was
  # pinned once. That is not a stricter suite than no suite, it is a suite
  # describing a different system.
  defp series_instance(attrs \\ []),
    do: event([recurring_event_id: "master_abc123"] ++ attrs)

  describe "mirror_source?/3 — recurrence turns on the target" do
    # The write gate is the only place the target's provider is known, and a
    # recurring source is the one case whose answer depends on it: Google
    # expands a series it is handed, so one placeholder carries the whole
    # thing, while a target that cannot would receive a single block at
    # whichever occurrence the cache happened to keep.
    test "a Google instance is recognised as recurring by its master id" do
      instance = series_instance()

      assert instance.recurrence_rule == nil,
             "a Google instance carries no rule — see the note above"

      assert Eligibility.mirror_source?(instance, MapSet.new(), "google", "google")

      refute Eligibility.mirror_source?(instance, MapSet.new(), "outlook", "google"),
             "a series must not be handed to a target that cannot expand one"
    end

    test "a one-off carrying neither mark is eligible for any target" do
      one_off = event(recurrence_rule: nil, recurring_event_id: nil)

      for provider <- ~w(google outlook caldav) do
        assert Eligibility.mirror_source?(one_off, MapSet.new(), provider),
               "#{provider} should take an ordinary event"
      end
    end

    test "a recurring source is eligible for a target that expands a series" do
      assert Eligibility.mirror_source?(series_instance(), MapSet.new(), "google", "google")
    end

    test "the same recurring source is skipped for an Outlook target" do
      refute Eligibility.mirror_source?(series_instance(), MapSet.new(), "outlook", "google")
    end

    # A CalDAV target now *is* handed a recurring source, and the refusal that
    # used to sit here was lifted on evidence rather than on a reading: a live
    # Radicale stored the RRULE and the EXDATE beside it and expanded the series
    # to four occurrences instead of five, the cancelled one gone. The gap that
    # justified the old refusal — a mirror payload's exception lines having no
    # mapper on the CalDAV path — was closed by
    # `ICalBuilder.Properties.build_exception_lines/1`.
    #
    # Outlook's refusal above is unchanged and is the contrast worth keeping in
    # view: its mapper still reads the rule alone.
    test "and now for a CalDAV target too, which can expand one" do
      for provider <- ~w(caldav nextcloud radicale apple) do
        assert Eligibility.mirror_source?(series_instance(), MapSet.new(), provider, "google"),
               "#{provider} can hold a series with its cancellations; see Capability"
      end
    end

    # The one rule-only case, and the only ingest that produces it: a row
    # carrying an RRULE and no master id comes from a non-Google source — an ICS
    # subscription, a CalDAV server that returns masters unexpanded — or from a
    # Google row cached before expansion was turned on. It is still a series and
    # still refused by a target that cannot expand one, which is what the second
    # `recurring?/1` clause exists for.
    #
    # It stays a single test deliberately. Marking recurrence this way is the
    # exception, and a suite that spreads it across every case describes the
    # ingest nobody has rather than the one everybody does.
    test "a rule with no master id is still a series: the non-Google ingest path" do
      rule_only = event(recurrence_rule: "FREQ=WEEKLY;COUNT=10", recurring_event_id: nil)

      # Recognised as a series from either end, which is the point of the second
      # `recurring?/1` clause. It is refused by a target that cannot expand one
      # regardless of where it came from, and — since the ingest that produces
      # this shape is by definition not Google — refused again on the source
      # side, which the companion test in the source-side block asserts.
      assert Eligibility.mirror_source?(rule_only, MapSet.new(), "google", "google")
      refute Eligibility.mirror_source?(rule_only, MapSet.new(), "outlook", "google")
    end

    # Omitting the target is how every non-recurrence caller asks the question,
    # and the answer for a recurring source must be the conservative one: a
    # caller that does not know where the placeholder is going cannot have
    # established that the destination expands series.
    test "a recurring source is skipped when no target provider is named" do
      refute Eligibility.mirror_source?(series_instance(), MapSet.new())
    end

    # The target's capability never rescues an event refused for another
    # reason. A recurring mirror is still a leaf, and a recurring transparent
    # event still takes no time.
    test "a recurrence-capable pair does not override the other refusals" do
      recurring = [recurring_event_id: "master_abc123"]

      refute Eligibility.mirror_source?(
               event(recurring),
               MapSet.new([{@integration_id, "source-uid"}]),
               "google",
               "google"
             )

      refute Eligibility.mirror_source?(
               event(recurring ++ [transparency: :transparent]),
               MapSet.new(),
               "google",
               "google"
             )
    end

    # A cancelled row that names a series is one cancelled *occurrence*, not a
    # cancelled series: the cache keeps one row per series and `upsert_batch/1`
    # keeps the last entry, so the row reads `cancelled` as soon as the
    # occurrence sorting last is. Refusing it withheld the write carrying the
    # EXDATE that frees the cancelled slot, so the occurrence kept blocking its
    # time because its own correction was declined — measured live on four
    # cancelled occurrences of a running series.
    test "a cancelled occurrence of a series is still a source, so its EXDATE can be written" do
      assert Eligibility.mirror_source?(
               event(recurring_event_id: "master_abc123", status: :cancelled),
               MapSet.new(),
               "google",
               "google"
             )
    end

    # The counterpart, and the reason this is a narrowing rather than a removal.
    # An event naming no series is gone outright, and its placeholder must go.
    test "a cancelled one-off is still refused" do
      refute Eligibility.mirror_source?(
               event(status: :cancelled),
               MapSet.new(),
               "google",
               "google"
             )
    end

    test "a non-recurring source is unaffected by the target's provider" do
      for provider <- ["google", "outlook", "nextcloud", nil] do
        assert Eligibility.mirror_source?(event([]), MapSet.new(), provider)
      end
    end
  end

  describe "mirror_source?/4 — recurrence turns on the source too" do
    # The half the target-only gate missed, and it cost the whole feature its
    # point on the affected links. Resolving a series means fetching its master
    # from the **source**, and `RecurringSeries.api_module/1` can only do that
    # for Google. An Outlook or CalDAV source with a Google target passed the
    # old gate — the target expands a series, so the target-side question
    # answered yes — reached `RecurringSeries`, and came back
    # `{:skip, :provider_has_no_series_lookup}`. The worker discarded the job,
    # no placeholder was ever written, and the organiser's recurring meetings
    # went on being bookable over.
    #
    # A refusal at the gate is not a smaller version of that failure, it is a
    # different one: it is recorded and rendered, where the discard was silent.
    test "an Outlook source is admitted: its master can be fetched" do
      assert Eligibility.mirror_source?(series_instance(), MapSet.new(), "google", "outlook"),
             "Outlook has a single-event GET, so the series master is reachable"
    end

    test "a CalDAV source is refused even by a target that expands a series" do
      for provider <- ~w(caldav nextcloud radicale apple baikal zimbra) do
        refute Eligibility.mirror_source?(series_instance(), MapSet.new(), "google", provider),
               "#{provider} cannot have a series master looked up"
      end
    end

    test "an ICS source is refused even by a target that expands a series" do
      refute Eligibility.mirror_source?(series_instance(), MapSet.new(), "google", "ics_url")
    end

    # Both halves must hold, so each one alone is enough to refuse. Asserted as
    # a matrix rather than as two examples: the bug was precisely that one of
    # the two conjuncts was missing, and a test naming only the pair that both
    # fail would pass against either half on its own.
    # The source side admits Google and Outlook — both have a single-event GET
    # the master can be read through — while the target side is Google's alone,
    # because only Google's outbound mapper carries the exception lines a series
    # needs. So the matrix is not symmetric, and asserting it as a matrix is
    # what keeps the two halves from being collapsed back into one question.
    test "both sides must answer, and they answer different questions" do
      # Spelled out per pair rather than derived from `Capability`, so that a
      # change to the capability rows has to be restated here deliberately
      # instead of being mirrored into the expectation automatically. The two
      # sides are genuinely independent: `nextcloud` is a valid *target* for a
      # series and never a valid *source* for one, because a CalDAV series is
      # expanded locally into one-offs that carry no master to fetch.
      source_can_supply = ~w(google outlook)
      target_can_receive = ~w(google nextcloud)

      for source <- ~w(google outlook nextcloud ics_url),
          target <- ~w(google outlook nextcloud ics_url) do
        expected = source in source_can_supply and target in target_can_receive

        assert Eligibility.mirror_source?(series_instance(), MapSet.new(), target, source) ==
                 expected,
               "source #{source} to target #{target} should be #{expected}"
      end
    end

    # The rule-only ingest is the one that makes the source side bite hardest.
    # A row carrying an RRULE and no master id comes from a non-Google source
    # by definition, so it is exactly the shape whose source can never be
    # resolved — and `RecurringSeries.resolve/2` refuses it as `:not_recurring`
    # before any fetch, which would mirror it as a one-off block at the cached
    # row's time if the gate let it through.
    test "a rule-only source is refused: the ingest that produces it is never Google" do
      rule_only = event(recurrence_rule: "FREQ=WEEKLY;COUNT=10", recurring_event_id: nil)

      refute Eligibility.mirror_source?(rule_only, MapSet.new(), "google", "nextcloud")
      refute Eligibility.mirror_source?(rule_only, MapSet.new(), "google", "ics_url")
    end

    # An unnamed source is the conservative refusal for the same reason an
    # unnamed target is: a caller that has not established the master can be
    # fetched has not established it, and a discarded job with no placeholder
    # is the outcome this gate exists to convert into a visible refusal.
    test "a recurring source is skipped when no source provider is named" do
      refute Eligibility.mirror_source?(series_instance(), MapSet.new(), "google", nil)
    end

    # The source side must not become a fourth refusal applying to ordinary
    # events. Only a series needs a master fetched; a one-off carries its own
    # times and mirrors from any source to any capable target.
    test "a one-off mirrors from a source that could never resolve a series" do
      one_off = event(recurrence_rule: nil, recurring_event_id: nil)

      for source <- ~w(google outlook nextcloud ics_url) do
        assert Eligibility.mirror_source?(one_off, MapSet.new(), "google", source),
               "an ordinary event from #{source} needs no master fetch"
      end
    end

    # Cache rows reach this gate as often as structs do — the worker re-reads
    # the row — and their fields are strings. A source-side clause that matched
    # only the struct shape would pass every test above and refuse nothing on
    # the path the worker actually takes.
    test "accepts a cache row on the source side too" do
      row = %Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema{
        uid: "source-uid",
        calendar_integration_id: @integration_id,
        transparency: "opaque",
        status: "confirmed",
        recurring_event_id: "master_abc123"
      }

      assert Eligibility.mirror_source?(row, MapSet.new(), "google", "google")
      refute Eligibility.mirror_source?(row, MapSet.new(), "google", "nextcloud")
    end
  end

  describe "worth_enqueueing?/2" do
    test "an ordinary event is worth a job" do
      assert Eligibility.worth_enqueueing?(event([]), MapSet.new())
    end

    test "a mirror is refused here as firmly as at the write" do
      refute Eligibility.worth_enqueueing?(
               event([]),
               MapSet.new([{@integration_id, "source-uid"}])
             )
    end

    # The narrower gate no longer refuses recurrence, and it cannot: it is
    # asked once for a batch of events shared across every link out of the
    # source calendar, so the per-link target it would have to consult is not
    # in hand. A recurring event is now worth a job for the same reason a
    # cancelled one is — the answer differs per link, and only the worker holds
    # the link.
    test "a recurring event is worth a job: whether it can be mirrored is per link" do
      assert Eligibility.worth_enqueueing?(series_instance(), MapSet.new())
    end

    test "an event that has stopped blocking time is still worth a job" do
      # It may already have a placeholder holding a slot the organiser has just
      # freed, and only the worker knows whether one exists.
      assert Eligibility.worth_enqueueing?(event(transparency: :transparent), MapSet.new())
      assert Eligibility.worth_enqueueing?(event(status: :cancelled), MapSet.new())
      assert Eligibility.worth_enqueueing?(event(status: :declined), MapSet.new())
    end
  end

  describe "mirror_source?/3 — cache rows" do
    test "accepts a ProviderCalendarEventSchema row, whose fields are strings" do
      row = %Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema{
        uid: "source-uid",
        calendar_integration_id: @integration_id,
        transparency: "opaque",
        status: "confirmed"
      }

      assert Eligibility.mirror_source?(row, MapSet.new())
      refute Eligibility.mirror_source?(row, MapSet.new([{@integration_id, "source-uid"}]))
      refute Eligibility.mirror_source?(%{row | status: "cancelled"}, MapSet.new())
      refute Eligibility.mirror_source?(%{row | transparency: "transparent"}, MapSet.new())

      recurring = %{row | recurring_event_id: "master_abc123"}
      refute Eligibility.mirror_source?(recurring, MapSet.new(), "outlook", "google")
      assert Eligibility.mirror_source?(recurring, MapSet.new(), "google", "google")
    end
  end
end
