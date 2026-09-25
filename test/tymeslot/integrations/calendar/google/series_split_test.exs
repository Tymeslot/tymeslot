defmodule Tymeslot.Integrations.Calendar.Google.SeriesSplitTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Google.SeriesSplit

  # A weekly Monday series at 09:00 in Berlin from 1 June, thirty times, as
  # Google returns its master: one excluded Monday before the split and one
  # after, and one extra date before it.
  @master %{
    "id" => "series1",
    "iCalUID" => "series1@google.com",
    "etag" => "\"3181\"",
    "htmlLink" => "https://www.google.com/calendar/event?eid=series1",
    "sequence" => 2,
    "created" => "2026-05-20T10:00:00.000Z",
    "updated" => "2026-05-21T10:00:00.000Z",
    "kind" => "calendar#event",
    "organizer" => %{"email" => "owner@example.com", "self" => true},
    "creator" => %{"email" => "owner@example.com", "self" => true},
    "summary" => "Weekly sync",
    "description" => "Agenda in the doc",
    "colorId" => "5",
    "start" => %{"dateTime" => "2026-06-01T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
    "end" => %{"dateTime" => "2026-06-01T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
    "recurrence" => [
      "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=30",
      "EXDATE;TZID=Europe/Berlin:20260615T090000,20261116T090000",
      "RDATE;TZID=Europe/Berlin:20260620T090000"
    ]
  }

  # Monday 2 November, after the change to winter time: 09:00 in Berlin is
  # 08:00 UTC there. Twenty-two Mondays of the series come before it.
  @slot ~U[2026-11-02 08:00:00Z]

  defp edit(changes \\ %{}, slot \\ @slot) do
    %{
      scope: :following,
      master_id: "series1",
      slot: slot,
      start: @slot,
      end: DateTime.add(@slot, 3600),
      changes: Map.merge(%{start_time: @slot, end_time: DateTime.add(@slot, 3600)}, changes)
    }
  end

  describe "the tail" do
    test "starts at the slot in the master's zone, with the occurrences left" do
      assert {:ok, %{tail: tail}} = SeriesSplit.build(@master, edit())

      assert tail["start"] == %{
               "dateTime" => "2026-11-02T09:00:00+01:00",
               "timeZone" => "Europe/Berlin"
             }

      assert tail["end"] == %{
               "dateTime" => "2026-11-02T10:00:00+01:00",
               "timeZone" => "Europe/Berlin"
             }

      assert tail["recurrence"] == [
               "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=8",
               "EXDATE;TZID=Europe/Berlin:20261116T090000"
             ]
    end

    test "keeps the master's fields and takes the edit's changes" do
      assert {:ok, %{tail: tail, head: head}} =
               SeriesSplit.build(@master, edit(%{summary: "Standup"}))

      assert tail["summary"] == "Standup"
      assert tail["description"] == "Agenda in the doc"
      assert tail["colorId"] == "5"
      assert head == %{"recurrence" => head["recurrence"]}
    end

    test "leaves out what Google assigns or manages itself" do
      assert {:ok, %{tail: tail}} = SeriesSplit.build(@master, edit())

      for key <- ~w(id iCalUID etag htmlLink sequence created updated kind organizer creator) do
        refute Map.has_key?(tail, key), "#{key} was copied"
      end
    end

    test "moves with the edit on the master's wall clock, exceptions and all" do
      moved = %{start_time: ~U[2026-11-02 09:00:00Z], end_time: ~U[2026-11-02 10:00:00Z]}

      assert {:ok, %{tail: tail, head: head}} = SeriesSplit.build(@master, edit(moved))

      assert tail["start"] == %{
               "dateTime" => "2026-11-02T10:00:00",
               "timeZone" => "Europe/Berlin"
             }

      assert tail["end"] == %{"dateTime" => "2026-11-02T11:00:00", "timeZone" => "Europe/Berlin"}

      assert tail["recurrence"] == [
               "RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=8",
               "EXDATE;TZID=Europe/Berlin:20261116T100000"
             ]

      assert head["recurrence"] |> hd() |> String.ends_with?("UNTIL=20261102T075959Z")
    end

    test "keeps an UNTIL as it is" do
      master = %{
        @master
        | "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261221T235959Z"]
      }

      assert {:ok, %{tail: tail}} = SeriesSplit.build(master, edit())
      assert tail["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261221T235959Z"]
    end

    test "copies the Meet the series has, never asking for a new one" do
      conference = %{
        "conferenceId" => "abc-defg-hij",
        "conferenceSolution" => %{"key" => %{"type" => "hangoutsMeet"}},
        "entryPoints" => [
          %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
        ],
        "createRequest" => %{"requestId" => "req-1", "status" => %{"statusCode" => "success"}}
      }

      master =
        Map.merge(@master, %{
          "conferenceData" => conference,
          "hangoutLink" => "https://meet.google.com/abc-defg-hij"
        })

      assert {:ok, %{tail: tail}} = SeriesSplit.build(master, edit())
      assert tail["conferenceData"] == Map.delete(conference, "createRequest")
      refute Map.has_key?(tail, "hangoutLink")
    end
  end

  describe "the head" do
    test "ends a second before the slot in UTC, and keeps the exceptions before it" do
      assert {:ok, %{head: head}} = SeriesSplit.build(@master, edit())

      assert head == %{
               "recurrence" => [
                 "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261102T075959Z",
                 "EXDATE;TZID=Europe/Berlin:20260615T090000",
                 "RDATE;TZID=Europe/Berlin:20260620T090000"
               ]
             }
    end
  end

  describe "an all-day series" do
    @all_day %{
      "id" => "days1",
      "summary" => "Conference",
      "start" => %{"date" => "2026-06-01"},
      "end" => %{"date" => "2026-06-02"},
      "recurrence" => ["RRULE:FREQ=DAILY;COUNT=10", "EXDATE;VALUE=DATE:20260603,20260606"]
    }

    test "is split on the slot's day, the head ending the day before" do
      edit = %{
        scope: :following,
        master_id: "days1",
        slot: ~D[2026-06-04],
        start: ~D[2026-06-04],
        end: ~D[2026-06-05],
        changes: %{start_time: ~D[2026-06-04], end_time: ~D[2026-06-05]}
      }

      assert {:ok, %{tail: tail, head: head}} = SeriesSplit.build(@all_day, edit)

      assert tail["start"] == %{"date" => "2026-06-04"}
      assert tail["end"] == %{"date" => "2026-06-05"}
      assert tail["recurrence"] == ["RRULE:FREQ=DAILY;COUNT=7", "EXDATE;VALUE=DATE:20260606"]

      assert head["recurrence"] == [
               "RRULE:FREQ=DAILY;UNTIL=20260603",
               "EXDATE;VALUE=DATE:20260603"
             ]
    end
  end

  describe "what is not split" do
    test "the first occurrence is an edit of every occurrence" do
      assert SeriesSplit.build(@master, edit(%{}, ~U[2026-06-01 07:00:00Z])) ==
               :first_occurrence
    end

    test "a count the grid cannot count as Google does is refused" do
      master = %{@master | "recurrence" => ["RRULE:FREQ=MONTHLY;BYDAY=1MO;COUNT=10"]}

      assert SeriesSplit.build(master, edit()) == {:error, :unsupported_rule}
    end

    test "a master without a rule is refused" do
      assert SeriesSplit.build(Map.delete(@master, "recurrence"), edit()) ==
               {:error, :not_recurring}
    end
  end
end
