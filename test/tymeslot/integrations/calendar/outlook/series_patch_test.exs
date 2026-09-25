defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesPatchTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Outlook.SeriesPatch

  @zone "W. Europe Standard Time"

  @range %{
    "type" => "endDate",
    "startDate" => "2026-06-01",
    "endDate" => "2026-12-31",
    "recurrenceTimeZone" => @zone
  }

  # A weekly Monday series at 09:00 in Berlin, as Graph returns its master
  # to a client that asks for UTC.
  @master %{
    "id" => "master-1",
    "type" => "seriesMaster",
    "subject" => "Weekly sync",
    "isAllDay" => false,
    "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
    "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
    "originalStartTimeZone" => @zone,
    "recurrence" => %{
      "pattern" => %{
        "type" => "weekly",
        "interval" => 1,
        "daysOfWeek" => ["monday"],
        "firstDayOfWeek" => "sunday"
      },
      "range" => @range
    }
  }

  # The occurrence of Monday 2 November, after the change to winter time.
  @occurrence_start ~U[2026-11-02 08:00:00Z]
  @occurrence_end ~U[2026-11-02 09:00:00Z]

  defp edit(changes) do
    %{
      scope: :all,
      master_id: "master-1",
      start: @occurrence_start,
      end: @occurrence_end,
      changes: Map.merge(%{start_time: @occurrence_start, end_time: @occurrence_end}, changes)
    }
  end

  defp tuesday, do: %{start_time: ~U[2026-11-03 08:00:00Z], end_time: ~U[2026-11-03 09:00:00Z]}

  describe "a move of the occurrence" do
    test "moves the master an hour on the wall clock of the zone it was created in" do
      edit = edit(%{start_time: ~U[2026-11-02 09:00:00Z], end_time: ~U[2026-11-02 10:00:00Z]})

      assert SeriesPatch.build(@master, edit) ==
               {:ok,
                %{
                  "start" => %{"dateTime" => "2026-06-01T10:00:00", "timeZone" => @zone},
                  "end" => %{"dateTime" => "2026-06-01T11:00:00", "timeZone" => @zone}
                }}
    end

    test "Monday to Tuesday turns the pattern and starts the range on the new date" do
      assert {:ok, body} = SeriesPatch.build(@master, edit(tuesday()))

      assert body["start"] == %{"dateTime" => "2026-06-02T09:00:00", "timeZone" => @zone}

      assert body["recurrence"] == %{
               "pattern" => %{
                 "type" => "weekly",
                 "interval" => 1,
                 "daysOfWeek" => ["tuesday"],
                 "firstDayOfWeek" => "sunday"
               },
               "range" => %{@range | "startDate" => "2026-06-02"}
             }
    end

    test "an absolute monthly series moves to the new day of the month" do
      master =
        put_in(@master, ["recurrence", "pattern"], %{
          "type" => "absoluteMonthly",
          "interval" => 1,
          "dayOfMonth" => 1
        })

      assert {:ok, body} = SeriesPatch.build(master, edit(tuesday()))
      assert body["recurrence"]["pattern"]["dayOfMonth"] == 2
      assert body["recurrence"]["range"]["startDate"] == "2026-06-02"
    end

    test "a relative monthly series refuses a move to another date" do
      master =
        put_in(@master, ["recurrence", "pattern"], %{
          "type" => "relativeMonthly",
          "interval" => 1,
          "daysOfWeek" => ["monday"],
          "index" => "second"
        })

      assert SeriesPatch.build(master, edit(tuesday())) == {:error, :rule_pins_occurrences}
    end

    test "every other week refuses a turn across the week start Graph counts from" do
      master =
        update_in(@master, ["recurrence", "pattern"], fn pattern ->
          %{pattern | "interval" => 2, "daysOfWeek" => ["saturday"]}
        end)

      # Saturday to Sunday crosses Graph's default week start, Sunday.
      edit = %{
        edit(%{start_time: ~U[2026-11-08 08:00:00Z], end_time: ~U[2026-11-08 09:00:00Z]})
        | start: ~U[2026-11-07 08:00:00Z],
          end: ~U[2026-11-07 09:00:00Z]
      }

      assert SeriesPatch.build(master, edit) == {:error, :rule_pins_occurrences}
    end

    test "a series in a zone that cannot be read refuses a move" do
      master = %{@master | "originalStartTimeZone" => "tzone://Microsoft/Custom"}
      edit = edit(%{start_time: ~U[2026-11-02 09:00:00Z], end_time: ~U[2026-11-02 10:00:00Z]})

      assert SeriesPatch.build(master, edit) == {:error, :unreadable_timing}

      assert SeriesPatch.build(master, edit(%{summary: "Standup"})) ==
               {:ok, %{"subject" => "Standup"}}
    end
  end

  describe "a change of fields alone" do
    test "patches only the changed keys" do
      assert SeriesPatch.build(@master, edit(%{summary: "Standup", location: "Room 2"})) ==
               {:ok, %{"subject" => "Standup", "location" => %{"displayName" => "Room 2"}}}
    end

    test "cleared reminders turn the reminder off" do
      assert SeriesPatch.build(@master, edit(%{reminders: []})) ==
               {:ok, %{"isReminderOn" => false}}
    end
  end

  describe "a new rule" do
    test "without an end keeps the master's range" do
      assert SeriesPatch.build(@master, edit(%{recurrence_rule: "FREQ=DAILY"})) ==
               {:ok,
                %{
                  "recurrence" => %{
                    "pattern" => %{"type" => "daily", "interval" => 1},
                    "range" => @range
                  }
                }}
    end

    test "with an end sends the range it states" do
      assert {:ok, %{"recurrence" => recurrence}} =
               SeriesPatch.build(@master, edit(%{recurrence_rule: "FREQ=DAILY;COUNT=5"}))

      assert recurrence["range"] == %{
               "type" => "numbered",
               "numberOfOccurrences" => 5,
               "startDate" => "2026-06-01"
             }
    end
  end
end
