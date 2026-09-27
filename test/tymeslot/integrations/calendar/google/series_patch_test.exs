defmodule Tymeslot.Integrations.Calendar.Google.SeriesPatchTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Google.SeriesPatch
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  @exdate "EXDATE;TZID=Europe/Berlin:20260615T090000"
  @rdate "RDATE;TZID=Europe/Berlin:20260620T090000"

  # A weekly Monday series at 09:00 in Berlin, as Google returns its master:
  # a summer start, one excluded Monday and one extra date.
  @master %{
    "id" => "series1",
    "summary" => "Weekly sync",
    "start" => %{"dateTime" => "2026-06-01T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
    "end" => %{"dateTime" => "2026-06-01T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
    "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO", @exdate, @rdate],
    "reminders" => %{
      "useDefault" => false,
      "overrides" => [%{"method" => "popup", "minutes" => 5}]
    },
    "colorId" => "5"
  }

  # The occurrence of Monday 2 November, after the change to winter time:
  # 09:00 in Berlin is 08:00 UTC there.
  @occurrence_start ~U[2026-11-02 08:00:00Z]
  @occurrence_end ~U[2026-11-02 09:00:00Z]

  defp edit(changes) do
    %{
      scope: :all,
      master_id: "series1",
      start: @occurrence_start,
      end: @occurrence_end,
      changes: Map.merge(%{start_time: @occurrence_start, end_time: @occurrence_end}, changes)
    }
  end

  describe "a move of the occurrence" do
    test "moves the master an hour on its own wall clock, not by the instant" do
      # 10:00 in Berlin in November; the June master becomes 10:00 in Berlin
      # too, though that is 08:00 UTC rather than 09:00.
      edit = edit(%{start_time: ~U[2026-11-02 09:00:00Z], end_time: ~U[2026-11-02 10:00:00Z]})

      assert {:ok, body} = SeriesPatch.build(@master, edit)

      assert body["start"] == %{
               "dateTime" => "2026-06-01T10:00:00",
               "timeZone" => "Europe/Berlin"
             }

      assert body["end"] == %{"dateTime" => "2026-06-01T11:00:00", "timeZone" => "Europe/Berlin"}

      assert body["recurrence"] == [
               "RRULE:FREQ=WEEKLY;BYDAY=MO",
               "EXDATE;TZID=Europe/Berlin:20260615T100000",
               "RDATE;TZID=Europe/Berlin:20260620T100000"
             ]

      refute Map.has_key?(body, "summary")
      refute Map.has_key?(body, "reminders")
    end

    test "a new duration gives the master that duration from its new start" do
      edit = edit(%{end_time: ~U[2026-11-02 08:30:00Z]})

      assert {:ok, body} = SeriesPatch.build(@master, edit)

      assert body["start"] == %{
               "dateTime" => "2026-06-01T09:00:00",
               "timeZone" => "Europe/Berlin"
             }

      assert body["end"] == %{"dateTime" => "2026-06-01T09:30:00", "timeZone" => "Europe/Berlin"}
      refute Map.has_key?(body, "recurrence")
    end

    test "Monday to Tuesday turns the rule's weekday and moves the dates the series names" do
      edit = edit(%{start_time: ~U[2026-11-03 08:00:00Z], end_time: ~U[2026-11-03 09:00:00Z]})

      assert {:ok, body} = SeriesPatch.build(@master, edit)

      assert body["start"] == %{
               "dateTime" => "2026-06-02T09:00:00",
               "timeZone" => "Europe/Berlin"
             }

      assert body["recurrence"] == [
               "RRULE:FREQ=WEEKLY;BYDAY=TU",
               "EXDATE;TZID=Europe/Berlin:20260616T090000",
               "RDATE;TZID=Europe/Berlin:20260621T090000"
             ]
    end

    test "an excluded UTC instant moves as an instant" do
      master = %{
        @master
        | "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE:20260615T070000Z"]
      }

      edit = edit(%{start_time: ~U[2026-11-03 08:00:00Z], end_time: ~U[2026-11-03 09:00:00Z]})

      assert {:ok, body} = SeriesPatch.build(master, edit)
      assert "EXDATE:20260616T070000Z" in body["recurrence"]
    end

    test "a monthly rule on the second Monday refuses a move to another date" do
      master = %{@master | "recurrence" => ["RRULE:FREQ=MONTHLY;BYDAY=2MO"]}
      edit = edit(%{start_time: ~U[2026-11-03 08:00:00Z], end_time: ~U[2026-11-03 09:00:00Z]})

      assert SeriesPatch.build(master, edit) == {:error, :rule_pins_occurrences}
    end

    test "an all-day series moves by whole days" do
      master = %{
        @master
        | "start" => %{"date" => "2026-06-01"},
          "end" => %{"date" => "2026-06-02"},
          "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE;VALUE=DATE:20260615"]
      }

      edit = %{
        scope: :all,
        master_id: "series1",
        start: ~D[2026-11-02],
        end: ~D[2026-11-03],
        changes: %{start_time: ~D[2026-11-03], end_time: ~D[2026-11-04]}
      }

      assert {:ok, body} = SeriesPatch.build(master, edit)
      assert body["start"] == %{"date" => "2026-06-02"}
      assert body["end"] == %{"date" => "2026-06-03"}
      assert body["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE;VALUE=DATE:20260616"]
    end

    test "turning a timed series all-day is refused" do
      edit = edit(%{start_time: ~D[2026-11-02], end_time: ~D[2026-11-03]})
      assert SeriesPatch.build(@master, edit) == {:error, :value_type_change}
    end
  end

  describe "a move of a series with an end" do
    # How many occurrences the master makes, expanded as the sync expands it.
    defp occurrences(%{"start" => %{"dateTime" => start, "timeZone" => zone}}, rule) do
      first = start |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!(zone)
      RecurrenceExpander.count_before(rule, first, ~U[2030-01-01 00:00:00Z])
    end

    defp ending(until),
      do: %{@master | "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=#{until}"]}

    # Monday 28 December 2026 is the last occurrence: 09:00 in Berlin is
    # 08:00 UTC, and the end of that day 22:59:59 UTC.
    for {bound, until} <- [
          {"the last occurrence's start", "20261228T080000Z"},
          {"the end of the last occurrence's day", "20261228T225959Z"}
        ],
        {move, start} <- [
          {"an hour later", ~U[2026-11-02 09:00:00Z]},
          {"a day later", ~U[2026-11-03 08:00:00Z]},
          {"an hour earlier", ~U[2026-11-02 07:00:00Z]},
          {"a day earlier", ~U[2026-11-01 08:00:00Z]}
        ] do
      test "ending at #{bound}, moved #{move}, keeps every occurrence" do
        master = ending(unquote(until))
        start = unquote(Macro.escape(start))

        assert {:ok, body} =
                 SeriesPatch.build(
                   master,
                   edit(%{start_time: start, end_time: DateTime.add(start, 1, :hour)})
                 )

        assert [rule] = body["recurrence"]
        assert occurrences(master, hd(master["recurrence"])) == 31
        assert occurrences(Map.merge(master, body), rule) == 31
      end
    end

    test "an UNTIL at the last occurrence moves by as much as the series" do
      edit = edit(%{start_time: ~U[2026-11-03 08:00:00Z], end_time: ~U[2026-11-03 09:00:00Z]})

      assert {:ok, body} = SeriesPatch.build(ending("20261228T080000Z"), edit)
      assert body["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261229T080000Z"]
    end

    test "an UNTIL moves on the series' wall clock, across a change of the clocks" do
      # Saturdays at 09:00 in Berlin, the last on 24 October (summer time,
      # 07:00 UTC), moved to Sundays: the last is then 25 October, in winter
      # time, at 08:00 UTC rather than a day's instant later.
      master = %{
        @master
        | "start" => %{"dateTime" => "2026-06-06T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
          "end" => %{"dateTime" => "2026-06-06T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
          "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=SA;UNTIL=20261024T070000Z"]
      }

      edit = %{
        scope: :all,
        master_id: "series1",
        start: ~U[2026-10-17 07:00:00Z],
        end: ~U[2026-10-17 08:00:00Z],
        changes: %{start_time: ~U[2026-10-18 07:00:00Z], end_time: ~U[2026-10-18 08:00:00Z]}
      }

      assert {:ok, body} = SeriesPatch.build(master, edit)
      assert body["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=SU;UNTIL=20261025T080000Z"]
      assert occurrences(master, hd(master["recurrence"])) == 21
      assert occurrences(Map.merge(master, body), hd(body["recurrence"])) == 21
    end

    test "an all-day series' date UNTIL moves by the same days and stays a date" do
      master = %{
        @master
        | "start" => %{"date" => "2026-06-01"},
          "end" => %{"date" => "2026-06-02"},
          "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261228"]
      }

      edit = %{
        scope: :all,
        master_id: "series1",
        start: ~D[2026-11-02],
        end: ~D[2026-11-03],
        changes: %{start_time: ~D[2026-11-03], end_time: ~D[2026-11-04]}
      }

      assert {:ok, body} = SeriesPatch.build(master, edit)
      assert body["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261229"]
    end

    test "a rule stated with the move keeps the UNTIL it was given" do
      edit =
        edit(%{
          start_time: ~U[2026-11-03 08:00:00Z],
          end_time: ~U[2026-11-03 09:00:00Z],
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU;UNTIL=20261229T225959Z"
        })

      assert {:ok, body} = SeriesPatch.build(ending("20261228T080000Z"), edit)
      assert body["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261229T225959Z"]
    end
  end

  describe "a change of fields alone" do
    test "patches only the changed key" do
      assert SeriesPatch.build(@master, edit(%{summary: "Standup"})) ==
               {:ok, %{"summary" => "Standup"}}
    end

    test "a cleared colour and reminders are sent cleared" do
      assert SeriesPatch.build(@master, edit(%{colour: nil, reminders: []})) ==
               {:ok, %{"colorId" => nil, "reminders" => %{"useDefault" => true}}}
    end
  end

  describe "a new rule" do
    test "replaces only the RRULE line and keeps the exceptions" do
      assert SeriesPatch.build(@master, edit(%{recurrence_rule: "FREQ=DAILY;COUNT=5"})) ==
               {:ok, %{"recurrence" => ["RRULE:FREQ=DAILY;COUNT=5", @exdate, @rdate]}}
    end

    test "with a move, is written as given while the exceptions move" do
      edit =
        edit(%{
          start_time: ~U[2026-11-03 08:00:00Z],
          end_time: ~U[2026-11-03 09:00:00Z],
          recurrence_rule: "FREQ=WEEKLY;BYDAY=WE"
        })

      assert {:ok, body} = SeriesPatch.build(@master, edit)

      assert body["recurrence"] == [
               "RRULE:FREQ=WEEKLY;BYDAY=WE",
               "EXDATE;TZID=Europe/Berlin:20260616T090000",
               "RDATE;TZID=Europe/Berlin:20260621T090000"
             ]
    end
  end
end
