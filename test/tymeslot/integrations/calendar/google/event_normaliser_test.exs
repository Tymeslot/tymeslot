defmodule Tymeslot.Integrations.Calendar.Google.EventNormaliserTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Google.EventNormaliser

  @context %{
    calendar_integration_id: 42,
    provider_calendar_id: "primary",
    synced_at: ~U[2026-04-08 12:00:00Z]
  }

  describe "normalise_events/2" do
    test "normalises a standard timed event with all fields" do
      raw_events = [
        %{
          "iCalUID" => "ical-uid-123@google.com",
          "id" => "event-id-123",
          "summary" => "Team Standup",
          "description" => "Daily sync",
          "location" => "Room 4B",
          "visibility" => "private",
          "transparency" => "opaque",
          "status" => "confirmed",
          "start" => %{
            "dateTime" => "2026-04-08T10:00:00+02:00",
            "timeZone" => "Europe/Berlin"
          },
          "end" => %{"dateTime" => "2026-04-08T10:30:00+02:00"},
          "organizer" => %{
            "email" => "boss@example.com",
            "displayName" => "The Boss"
          },
          "attendees" => [
            %{
              "email" => "dev@example.com",
              "displayName" => "Dev",
              "responseStatus" => "accepted",
              "optional" => false
            }
          ],
          "reminders" => %{
            "overrides" => [%{"method" => "popup", "minutes" => 10}]
          },
          "colorId" => "5",
          "etag" => "\"etag-abc\""
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert %CalendarEvent{} = event
      assert event.uid == "ical-uid-123@google.com"
      assert event.provider == :google
      assert event.calendar_integration_id == 42
      assert event.provider_calendar_id == "primary"
      assert event.synced_at == ~U[2026-04-08 12:00:00Z]
      assert event.summary == "Team Standup"
      assert event.description == "Daily sync"
      assert event.location == "Room 4B"
      assert event.visibility == :private
      assert event.transparency == :opaque
      assert event.status == :confirmed
      assert event.all_day == false
      # Shifted to UTC: 10:00+02:00 → 08:00Z
      assert event.start_at == ~U[2026-04-08 08:00:00Z]
      assert event.end_at == ~U[2026-04-08 08:30:00Z]
      assert event.timezone == "Europe/Berlin"
      assert event.organiser == %{email: "boss@example.com", display_name: "The Boss"}

      assert [attendee] = event.attendees
      assert attendee.email == "dev@example.com"
      assert attendee.display_name == "Dev"
      assert attendee.response_status == :accepted
      assert attendee.optional == false

      assert [reminder] = event.reminders
      assert reminder.method == :popup
      assert reminder.minutes_before == 10

      assert event.colour == "banana"
      assert event.etag == "\"etag-abc\""
      assert event.recurrence_rule == nil
      assert event.recurring_event_id == nil
    end

    test "normalises an all-day event" do
      raw_events = [
        %{
          "iCalUID" => "allday-uid@google.com",
          "id" => "allday-id",
          "summary" => "Bank Holiday",
          "start" => %{"date" => "2026-04-10"},
          "end" => %{"date" => "2026-04-11"},
          "status" => "confirmed"
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert event.all_day == true
      assert event.start_date == ~D[2026-04-10]
      assert event.end_date == ~D[2026-04-11]
      assert is_nil(event.start_at)
      assert is_nil(event.end_at)
    end

    test "normalises a cancelled event" do
      raw_events = [
        %{
          "iCalUID" => "cancelled-uid@google.com",
          "id" => "cancelled-id",
          "summary" => "Cancelled Meeting",
          "start" => %{"dateTime" => "2026-04-08T14:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T15:00:00Z"},
          "status" => "cancelled"
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert event.status == :cancelled
    end

    test "normalises a transparent (free) event" do
      raw_events = [
        %{
          "iCalUID" => "free-uid@google.com",
          "id" => "free-id",
          "summary" => "Lunch",
          "start" => %{"dateTime" => "2026-04-08T12:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T13:00:00Z"},
          "transparency" => "transparent"
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert event.transparency == :transparent
      refute CalendarEvent.blocking?(event)
    end

    test "normalises event with multiple attendees" do
      raw_events = [
        %{
          "iCalUID" => "attendees-uid@google.com",
          "id" => "attendees-id",
          "summary" => "Group Call",
          "start" => %{"dateTime" => "2026-04-08T16:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T17:00:00Z"},
          "attendees" => [
            %{
              "email" => "alice@example.com",
              "displayName" => "Alice",
              "responseStatus" => "accepted"
            },
            %{
              "email" => "bob@example.com",
              "responseStatus" => "declined",
              "optional" => true
            },
            %{
              "email" => "charlie@example.com",
              "responseStatus" => "tentative"
            }
          ]
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert length(event.attendees) == 3

      alice = Enum.find(event.attendees, &(&1.email == "alice@example.com"))
      assert alice.display_name == "Alice"
      assert alice.response_status == :accepted
      assert alice.optional == false

      bob = Enum.find(event.attendees, &(&1.email == "bob@example.com"))
      assert bob.response_status == :declined
      assert bob.optional == true
    end

    test "falls back to id when iCalUID is missing" do
      raw_events = [
        %{
          "id" => "fallback-id",
          "summary" => "No iCalUID",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.uid == "fallback-id"
    end

    test "skips invalid event with no UID and continues processing" do
      raw_events = [
        %{
          "summary" => "No UID Event",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        },
        %{
          "iCalUID" => "valid-uid@google.com",
          "id" => "valid-id",
          "summary" => "Valid Event",
          "start" => %{"dateTime" => "2026-04-08T12:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T13:00:00Z"}
        }
      ]

      assert {:ok, events} = EventNormaliser.normalise_events(raw_events, @context)
      assert length(events) == 1
      assert hd(events).uid == "valid-uid@google.com"
    end

    test "returns empty list when all events are invalid" do
      raw_events = [
        %{"summary" => "No UID"},
        %{"summary" => "Also No UID"}
      ]

      assert {:ok, []} = EventNormaliser.normalise_events(raw_events, @context)
    end

    test "returns empty list for empty input" do
      assert {:ok, []} = EventNormaliser.normalise_events([], @context)
    end

    test "detects Tymeslot-created event via extendedProperties" do
      raw_events = [
        %{
          "iCalUID" => "tymeslot-uid@google.com",
          "id" => "tymeslot-id",
          "summary" => "Booking",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"},
          "extendedProperties" => %{"private" => %{"createdBy" => "tymeslot"}}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.created_by_tymeslot == true
    end

    test "marks non-Tymeslot event as not created by Tymeslot" do
      raw_events = [
        %{
          "iCalUID" => "other-uid@google.com",
          "id" => "other-id",
          "summary" => "External Meeting",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.created_by_tymeslot == false
    end

    test "maps an unknown Google colorId to nil colour" do
      raw_events = [
        %{
          "iCalUID" => "evt-x@google.com",
          "id" => "evt-x",
          "summary" => "X",
          "colorId" => "999",
          "start" => %{"dateTime" => "2026-07-02T10:00:00Z"},
          "end" => %{"dateTime" => "2026-07-02T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.colour == nil
    end
  end

  # Google splits a recurring series across two kinds of event, and puts the two
  # recurrence fields on opposite sides of that split: `recurrence` (the RRULE
  # array) on the series **master**, `recurringEventId` (the master's id) on each
  # expanded **instance**. No single event carries both — measured on a live
  # installation, 0 of 224 cached Google rows do — so the pair is not a rare
  # shape to be tolerant of, it is one that does not occur.
  #
  # `GoogleCalendarApi.list_events/4` sends `singleEvents=true`
  # (`google_calendar_api.ex:60`), so a sync only ever sees the instance side and
  # the master is never normalised by this module at all. The master case below
  # is covered because `get_event/3` fetches one directly — that is the single
  # place a Google recurrence rule exists in the system — not because a listing
  # could produce it.
  describe "recurrence markers, which Google splits across master and instance" do
    defp series_event(attrs) do
      Map.merge(
        %{
          "iCalUID" => "weekly-series@google.com",
          "id" => "master_abc123",
          "summary" => "Weekly standup",
          "start" => %{"dateTime" => "2026-12-15T09:00:00Z"},
          "end" => %{"dateTime" => "2026-12-15T09:30:00Z"}
        },
        attrs
      )
    end

    test "a series master carries the rule and names no master of its own" do
      raw = [series_event(%{"recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=TU"]})]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"
      assert event.recurring_event_id == nil
    end

    test "a series master keeps the first line when Google appends exceptions" do
      raw = [
        series_event(%{
          "recurrence" => [
            "RRULE:FREQ=WEEKLY;BYDAY=TU",
            "EXDATE;TZID=Europe/Tallinn:20261215T090000"
          ]
        })
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.recurrence_rule == "RRULE:FREQ=WEEKLY;BYDAY=TU"
    end

    test "a series instance names its master and carries no rule" do
      raw = [
        series_event(%{
          "id" => "master_abc123_20261215T090000Z",
          "recurringEventId" => "master_abc123"
        })
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.recurring_event_id == "master_abc123"
      assert event.recurrence_rule == nil
    end

    # THE INVARIANT. Every Google row that reaches the cache comes from a
    # `singleEvents=true` listing, so it is an expanded instance: it names its
    # master and its `recurrence_rule` is nil. `RecurringSeries.recurring?/1`
    # gates on `recurring_event_id` for exactly this reason, and a regression
    # flipping that gate back to reading `recurrence_rule` answers "not
    # recurring" for every row that has ever existed — which makes the master
    # fetch unreachable and mirrors each series as one busy block at the last
    # occurrence's date. That defect shipped once. Nothing else in the suite
    # pins that the rule side of the pair is empty on a listed row, so this test
    # is what stands between the gate and its own history.
    test "every event from a singleEvents listing names a master and carries no rule" do
      raw =
        for offset <- 0..2 do
          series_event(%{
            "id" => "master_abc123_2026121#{5 + offset}T090000Z",
            "start" => %{"dateTime" => "2026-12-1#{5 + offset}T09:00:00Z"},
            "end" => %{"dateTime" => "2026-12-1#{5 + offset}T09:30:00Z"},
            "recurringEventId" => "master_abc123"
          })
        end

      assert {:ok, events} = EventNormaliser.normalise_events(raw, @context)
      assert length(events) == 3

      for event <- events do
        assert event.recurring_event_id == "master_abc123"

        assert event.recurrence_rule == nil,
               "a listed Google row carried a recurrence_rule: #{inspect(event.recurrence_rule)}"
      end
    end
  end

  # Google records a moved occurrence as its own exception instance carrying
  # `originalStartTime` — where the occurrence used to sit. Without it, the
  # instance is indistinguishable from an ordinary one, because the master's
  # RRULE is untouched by a move and no EXDATE is added.
  describe "originalStartTime on a moved occurrence" do
    defp instance(attrs) do
      Map.merge(
        %{
          "iCalUID" => "weekly@google.com",
          "id" => "master_abc_20261215T090000Z",
          "summary" => "Weekly standup",
          "recurringEventId" => "master_abc"
        },
        attrs
      )
    end

    test "captures a timed move, shifted to UTC like the start it is compared against" do
      raw = [
        instance(%{
          "start" => %{"dateTime" => "2026-12-15T11:00:00+02:00"},
          "end" => %{"dateTime" => "2026-12-15T11:30:00+02:00"},
          "originalStartTime" => %{"dateTime" => "2026-12-15T09:00:00+02:00"}
        })
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.original_start_at == ~U[2026-12-15 07:00:00Z]
      assert event.start_at == ~U[2026-12-15 09:00:00Z]
    end

    test "captures an all-day move as a Date, matching the start_date it is compared against" do
      raw = [
        instance(%{
          "start" => %{"date" => "2026-12-16"},
          "end" => %{"date" => "2026-12-17"},
          "originalStartTime" => %{"date" => "2026-12-15"}
        })
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.original_start_at == ~D[2026-12-15]
      assert event.start_date == ~D[2026-12-16]
    end

    test "leaves an ordinary instance of a series nil" do
      raw = [
        instance(%{
          "start" => %{"dateTime" => "2026-12-15T09:00:00Z"},
          "end" => %{"dateTime" => "2026-12-15T09:30:00Z"}
        })
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.original_start_at == nil
      assert event.recurring_event_id == "master_abc"
    end

    test "leaves a non-recurring event nil" do
      raw = [
        %{
          "iCalUID" => "one-off@google.com",
          "id" => "one-off",
          "summary" => "Lunch",
          "start" => %{"dateTime" => "2026-12-15T12:00:00Z"},
          "end" => %{"dateTime" => "2026-12-15T13:00:00Z"}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.original_start_at == nil
    end

    # A malformed value must not cost the event, let alone the sync job it runs
    # inside. `parse_timing/1` falls back rather than raising on the same input,
    # and the marker is strictly less important than the times themselves.
    test "leaves a malformed value nil without dropping the event" do
      for bad <- [
            %{"dateTime" => "not-a-timestamp"},
            %{"date" => "2026-13-45"},
            %{"dateTime" => 1_234_567_890},
            %{"timeZone" => "Europe/Tallinn"},
            "2026-12-15T09:00:00Z"
          ] do
        raw = [
          instance(%{
            "start" => %{"dateTime" => "2026-12-15T11:00:00Z"},
            "end" => %{"dateTime" => "2026-12-15T11:30:00Z"},
            "originalStartTime" => bad
          })
        ]

        assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
        assert event.original_start_at == nil, "expected nil for #{inspect(bad)}"
        assert event.start_at == ~U[2026-12-15 11:00:00Z]
      end
    end
  end

  # Google reports its own last-write time as `updated`, an RFC3339 instant with
  # milliseconds. It is what every staleness comparison downstream is written
  # against — `SyncLinkReconcileWorker.stale?/2`, `ConflictLog`'s
  # `compared_by => "provider_updated_at"` path — and none of them can fire
  # while the normaliser drops the field.
  describe "normalise_events/2 provider_updated_at" do
    defp updatable(attrs) do
      Map.merge(
        %{
          "iCalUID" => "updated@google.com",
          "id" => "updated-1",
          "summary" => "Review",
          "start" => %{"dateTime" => "2026-08-17T09:00:00Z"},
          "end" => %{"dateTime" => "2026-08-17T09:30:00Z"}
        },
        attrs
      )
    end

    test "maps Google's `updated` onto provider_updated_at" do
      raw = [updatable(%{"updated" => "2026-08-17T14:32:11.123Z"})]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.provider_updated_at == ~U[2026-08-17 14:32:11.123Z]
    end

    test "shifts an offset-bearing value to UTC" do
      raw = [updatable(%{"updated" => "2026-08-17T16:32:11.000+02:00"})]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
      assert event.provider_updated_at == ~U[2026-08-17 14:32:11.000Z]
      assert event.provider_updated_at.time_zone == "Etc/UTC"
    end

    test "leaves an absent value nil" do
      assert {:ok, [event]} = EventNormaliser.normalise_events([updatable(%{})], @context)
      assert event.provider_updated_at == nil
    end

    # Same trade as `parse_original_start/1`: a marker that could not be read is
    # never worth the event it rode in on, let alone the batch around it.
    test "leaves a malformed value nil without dropping the event" do
      for bad <- ["not-a-timestamp", "2026-13-45T00:00:00Z", 1_234_567_890, %{"dateTime" => "x"}] do
        raw = [updatable(%{"updated" => bad})]

        assert {:ok, [event]} = EventNormaliser.normalise_events(raw, @context)
        assert event.provider_updated_at == nil, "expected nil for #{inspect(bad)}"
        assert event.start_at == ~U[2026-08-17 09:00:00Z]
      end
    end
  end
end
