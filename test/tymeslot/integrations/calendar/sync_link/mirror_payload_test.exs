defmodule Tymeslot.Integrations.Calendar.SyncLink.MirrorPayloadTest do
  @moduledoc """
  The `busy_only` placeholder payload.

  Two things are pinned here. The first is that nothing leaks: no description,
  no location, no attendees, no conferencing link, whatever the source carried.
  A placeholder that quietly copies a meeting title onto the organiser's work
  calendar is the failure this whole privacy tier exists to prevent.

  The second is the all-day branch. All-day rows leave `start_at`/`end_at` NULL
  and carry `start_date`/`end_date` instead — the 20260408110831 migration
  dropped those NOT NULL constraints for exactly that reason. A payload builder
  reading `start_at` unconditionally therefore produces `nil` for every all-day
  source, and every provider mapper keys off `%Date{}` in `start_time` to decide
  the event is all-day, so the mistake shows up as an invalid DTSTART rather
  than as a wrong-but-plausible time.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload

  @target_uid "tymeslot-mirror-abc123"

  defp link(attrs), do: struct!(%CalendarSyncLinkSchema{privacy_tier: "busy_only"}, attrs)

  defp timed_event(attrs \\ %{}) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: "source-uid",
          calendar_integration_id: 7,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "pid-1",
          summary: "Quarterly review with the board",
          description: "Agenda attached, discuss the redundancies",
          location: "Room 4, 12 Example Street",
          all_day: false,
          start_at: ~U[2026-07-03 09:30:00Z],
          end_at: ~U[2026-07-03 10:45:00Z],
          timezone: "Europe/Tallinn",
          synced_at: ~U[2026-07-01 00:00:00Z]
        },
        attrs
      )
    )
  end

  defp all_day_event(attrs \\ %{}) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: "source-uid",
          calendar_integration_id: 7,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "pid-1",
          summary: "Annual leave",
          all_day: true,
          start_date: ~D[2026-07-03],
          end_date: ~D[2026-07-04],
          timezone: "Europe/Tallinn",
          synced_at: ~U[2026-07-01 00:00:00Z]
        },
        attrs
      )
    )
  end

  describe "build/2 — timed events" do
    test "carries the source's instants and timezone" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      assert payload.uid == @target_uid
      assert payload.all_day == false
      assert payload.start_time == ~U[2026-07-03 09:30:00Z]
      assert payload.end_time == ~U[2026-07-03 10:45:00Z]
      assert payload.timezone == "Europe/Tallinn"
    end

    test "the title is the opaque placeholder, never the source's summary" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      assert payload.summary == "Busy"
    end

    test "no detail from the source reaches the placeholder" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      refute Map.has_key?(payload, :description)
      refute Map.has_key?(payload, :location)
      refute Map.has_key?(payload, :attendees)
      refute Map.has_key?(payload, :attendee_email)
      refute Map.has_key?(payload, :conference_url)
      refute Map.has_key?(payload, :conference_data)

      encoded = inspect(payload)
      refute encoded =~ "Quarterly review"
      refute encoded =~ "redundancies"
      refute encoded =~ "Example Street"
    end

    test "the placeholder is opaque, so it blocks time on the target" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      assert payload.transparency == :opaque
    end
  end

  describe "build/2 — all-day events" do
    test "populates the date fields and leaves the instants absent" do
      payload = MirrorPayload.build(all_day_event(), @target_uid)

      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-04]

      refute match?(%DateTime{}, payload.start_time)
      refute match?(%DateTime{}, payload.end_time)
    end

    test "a multi-day all-day source keeps its whole span" do
      multi_day = all_day_event(%{start_date: ~D[2026-07-03], end_date: ~D[2026-07-10]})
      payload = MirrorPayload.build(multi_day, @target_uid)

      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-10]
    end

    test "carries the source timezone through" do
      payload = MirrorPayload.build(all_day_event(), @target_uid)

      assert payload.timezone == "Europe/Tallinn"
    end

    test "the title is the placeholder here too" do
      payload = MirrorPayload.build(all_day_event(), @target_uid)

      assert payload.summary == "Busy"
      refute inspect(payload) =~ "Annual leave"
    end
  end

  describe "build/2 — cache rows" do
    test "reads the same fields off a ProviderCalendarEventSchema row" do
      row = %ProviderCalendarEventSchema{
        uid: "source-uid",
        calendar_integration_id: 7,
        summary: "Annual leave",
        all_day: true,
        start_date: ~D[2026-07-03],
        end_date: ~D[2026-07-04],
        timezone: "Europe/Tallinn"
      }

      payload = MirrorPayload.build(row, @target_uid)

      assert payload.uid == @target_uid
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.summary == "Busy"
    end
  end

  describe "build/3 — busy_only tier" do
    test "matches build/2 exactly, so the default tier has one rendering" do
      source = timed_event()

      assert MirrorPayload.build(source, @target_uid, link(%{privacy_tier: "busy_only"})) ==
               MirrorPayload.build(source, @target_uid)
    end

    test "carries the placeholder title and no source detail" do
      payload =
        MirrorPayload.build(timed_event(), @target_uid, link(%{privacy_tier: "busy_only"}))

      assert payload.summary == "Busy"
      refute Map.has_key?(payload, :description)
      refute Map.has_key?(payload, :location)
    end

    test "an all-day source keeps its date-valued timing" do
      payload =
        MirrorPayload.build(all_day_event(), @target_uid, link(%{privacy_tier: "busy_only"}))

      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-04]
    end
  end

  describe "build/3 — generic_label tier" do
    test "the organiser's label is the title, and nothing else is copied" do
      payload =
        MirrorPayload.build(
          timed_event(),
          @target_uid,
          link(%{privacy_tier: "generic_label", generic_label: "Personal commitment"})
        )

      assert payload.summary == "Personal commitment"
      refute Map.has_key?(payload, :description)
      refute Map.has_key?(payload, :location)

      encoded = inspect(payload)
      refute encoded =~ "Quarterly review"
      refute encoded =~ "redundancies"
      refute encoded =~ "Example Street"
    end

    test "a nil label falls back to busy_only rather than writing an empty title" do
      payload =
        MirrorPayload.build(
          timed_event(),
          @target_uid,
          link(%{privacy_tier: "generic_label", generic_label: nil})
        )

      assert payload.summary == "Busy"
    end

    test "a blank label falls back to busy_only" do
      for blank <- ["", "   ", "\t\n"] do
        payload =
          MirrorPayload.build(
            timed_event(),
            @target_uid,
            link(%{privacy_tier: "generic_label", generic_label: blank})
          )

        assert payload.summary == "Busy"
      end
    end

    test "the label is trimmed, so trailing whitespace never reaches the provider" do
      payload =
        MirrorPayload.build(
          timed_event(),
          @target_uid,
          link(%{privacy_tier: "generic_label", generic_label: "  Away  "})
        )

      assert payload.summary == "Away"
    end

    test "an all-day source still gets date-valued timing" do
      payload =
        MirrorPayload.build(
          all_day_event(),
          @target_uid,
          link(%{privacy_tier: "generic_label", generic_label: "Out of office"})
        )

      assert payload.summary == "Out of office"
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-04]
      refute inspect(payload) =~ "Annual leave"
    end
  end

  describe "build/3 — full_passthrough tier" do
    test "copies title, description and location" do
      payload =
        MirrorPayload.build(timed_event(), @target_uid, link(%{privacy_tier: "full_passthrough"}))

      assert payload.summary == "Quarterly review with the board"
      assert payload.description == "Agenda attached, discuss the redundancies"
      assert payload.location == "Room 4, 12 Example Street"
    end

    test "a source with no description or location omits the keys entirely" do
      source = timed_event(%{description: nil, location: nil})

      payload =
        MirrorPayload.build(source, @target_uid, link(%{privacy_tier: "full_passthrough"}))

      assert payload.summary == "Quarterly review with the board"
      refute Map.has_key?(payload, :description)
      refute Map.has_key?(payload, :location)
    end

    test "a source with no summary falls back to the placeholder title" do
      source = timed_event(%{summary: nil})

      payload =
        MirrorPayload.build(source, @target_uid, link(%{privacy_tier: "full_passthrough"}))

      assert payload.summary == "Busy"
    end

    test "the placeholder stays opaque, so it still blocks time" do
      payload =
        MirrorPayload.build(timed_event(), @target_uid, link(%{privacy_tier: "full_passthrough"}))

      assert payload.transparency == :opaque
      assert payload.status == :confirmed
    end

    test "an all-day source keeps its date-valued timing" do
      payload =
        MirrorPayload.build(
          all_day_event(),
          @target_uid,
          link(%{privacy_tier: "full_passthrough"})
        )

      assert payload.summary == "Annual leave"
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-04]
    end
  end

  describe "attendees and conferencing, at every tier" do
    @tiers [
      %{privacy_tier: "busy_only"},
      %{privacy_tier: "generic_label", generic_label: "Personal commitment"},
      %{privacy_tier: "full_passthrough"}
    ]

    test "no tier ever copies attendees or conferencing data" do
      source =
        timed_event(%{
          attendees: [
            %{email: "colleague@example.com", name: "A Colleague"},
            %{email: "board@example.com", name: "The Board"}
          ],
          organiser: "organiser@example.com",
          links: ["https://meet.example.com/secret-room"],
          provider_metadata: %{"hangoutLink" => "https://meet.example.com/secret-room"}
        })

      for tier <- @tiers do
        payload = MirrorPayload.build(source, @target_uid, link(tier))

        refute Map.has_key?(payload, :attendees)
        refute Map.has_key?(payload, :attendee_email)
        refute Map.has_key?(payload, :attendee_name)
        refute Map.has_key?(payload, :conference_url)
        refute Map.has_key?(payload, :conference_data)
        refute Map.has_key?(payload, :organizer)
        refute Map.has_key?(payload, :organiser)

        encoded = inspect(payload)
        refute encoded =~ "colleague@example.com"
        refute encoded =~ "board@example.com"
        refute encoded =~ "A Colleague"
        refute encoded =~ "meet.example.com"
      end
    end

    test "the payload's keys are a fixed, reviewable set at every tier" do
      allowed =
        MapSet.new([
          :uid,
          :summary,
          :description,
          :location,
          :transparency,
          :status,
          :all_day,
          :start_time,
          :end_time,
          :timezone
        ])

      for tier <- @tiers do
        payload = MirrorPayload.build(timed_event(), @target_uid, link(tier))
        extra = payload |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed)

        assert MapSet.size(extra) == 0,
               "unexpected key(s) in the #{tier.privacy_tier} payload: #{inspect(MapSet.to_list(extra))}"
      end
    end
  end

  describe "the series options" do
    test "the exception lines travel beside the rule" do
      payload =
        MirrorPayload.build(timed_event(), @target_uid, link(%{}),
          recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
          recurrence_exception_lines: [
            "EXDATE;TZID=Europe/Tallinn:20261013T090000"
          ]
        )

      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20261013T090000"
             ]
    end

    # The option is additive: a caller naming only the rule — every caller
    # before exception lines existed — gets exactly the payload it always did.
    test "a rule alone produces no exception key" do
      payload =
        MirrorPayload.build(timed_event(), @target_uid, link(%{}),
          recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU"
        )

      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"
      refute Map.has_key?(payload, :recurrence_exception_lines)
    end

    # An empty list is absent rather than present-and-empty, for the same
    # reason `put_present/3` drops a nil description: a key whose value says
    # nothing is a key the mapper has to decide about.
    test "an empty exception list is omitted rather than carried" do
      payload =
        MirrorPayload.build(timed_event(), @target_uid, link(%{}),
          recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
          recurrence_exception_lines: []
        )

      refute Map.has_key?(payload, :recurrence_exception_lines)
    end

    test "a non-recurring placeholder carries neither key" do
      payload = MirrorPayload.build(timed_event(), @target_uid, link(%{}))

      refute Map.has_key?(payload, :recurrence_rule)
      refute Map.has_key?(payload, :recurrence_exception_lines)
    end

    # The exceptions are a property of the timing, like the rule and the
    # opacity, so no tier suppresses them — a `busy_only` block that kept
    # blocking a cancelled occurrence would be wrong rather than private.
    test "every tier carries them, including a private source degraded to Busy" do
      for tier <- ["busy_only", "generic_label", "full_passthrough"] do
        payload =
          MirrorPayload.build(
            timed_event(%{visibility: :private}),
            @target_uid,
            link(%{privacy_tier: tier, generic_label: "Personal commitment"}),
            recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
            recurrence_exception_lines: ["EXDATE;TZID=Europe/Tallinn:20261013T090000"]
          )

        assert payload.summary == "Busy"

        assert payload.recurrence_exception_lines == [
                 "EXDATE;TZID=Europe/Tallinn:20261013T090000"
               ]
      end
    end
  end

  describe "the visibility override" do
    test "a private source never passes its title, even on full_passthrough" do
      source = timed_event(%{visibility: :private})

      payload =
        MirrorPayload.build(source, @target_uid, link(%{privacy_tier: "full_passthrough"}))

      assert payload.summary == "Busy"
      refute Map.has_key?(payload, :description)
      refute Map.has_key?(payload, :location)
      refute inspect(payload) =~ "Quarterly review"
      refute inspect(payload) =~ "redundancies"
    end

    test "a confidential source degrades the same way" do
      source = timed_event(%{visibility: :confidential})

      payload =
        MirrorPayload.build(source, @target_uid, link(%{privacy_tier: "full_passthrough"}))

      assert payload.summary == "Busy"
      refute Map.has_key?(payload, :description)
    end

    test "the string forms a cache row carries are honoured too" do
      for visibility <- ["private", "confidential"] do
        row = %ProviderCalendarEventSchema{
          uid: "source-uid",
          calendar_integration_id: 7,
          summary: "Quarterly review with the board",
          description: "Agenda attached",
          location: "Room 4",
          visibility: visibility,
          all_day: false,
          start_at: ~U[2026-07-03 09:30:00Z],
          end_at: ~U[2026-07-03 10:45:00Z]
        }

        payload = MirrorPayload.build(row, @target_uid, link(%{privacy_tier: "full_passthrough"}))

        assert payload.summary == "Busy"
        refute inspect(payload) =~ "Quarterly review"
      end
    end

    test "it beats generic_label too, so no organiser label labels a private event" do
      source = timed_event(%{visibility: :private})

      payload =
        MirrorPayload.build(
          source,
          @target_uid,
          link(%{privacy_tier: "generic_label", generic_label: "Personal commitment"})
        )

      assert payload.summary == "Busy"
    end

    test "a public or unset source is unaffected" do
      for visibility <- [:public, nil] do
        source = timed_event(%{visibility: visibility})

        payload =
          MirrorPayload.build(source, @target_uid, link(%{privacy_tier: "full_passthrough"}))

        assert payload.summary == "Quarterly review with the board"
      end
    end

    test "an all-day private source keeps its date timing while losing its title" do
      source = all_day_event(%{visibility: :private})

      payload =
        MirrorPayload.build(source, @target_uid, link(%{privacy_tier: "full_passthrough"}))

      assert payload.summary == "Busy"
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      refute inspect(payload) =~ "Annual leave"
    end
  end
end
