defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesSplitTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Outlook.SeriesSplit

  @zone "W. Europe Standard Time"

  @pattern %{
    "type" => "weekly",
    "interval" => 1,
    "daysOfWeek" => ["monday"],
    "firstDayOfWeek" => "sunday"
  }

  # A weekly Monday series at 09:00 in Berlin from 1 June, thirty times, as
  # Graph returns its master to a client that asks for UTC.
  @master %{
    "id" => "master-1",
    "iCalUId" => "040000008200E00074C5B7101A82E008",
    "changeKey" => "DwAAABYAAAA",
    "webLink" => "https://outlook.office365.com/owa/?itemid=master-1",
    "createdDateTime" => "2026-05-20T10:00:00Z",
    "type" => "seriesMaster",
    "subject" => "Weekly sync",
    "body" => %{"contentType" => "html", "content" => "<p>Agenda</p>"},
    "showAs" => "busy",
    "isAllDay" => false,
    "isOnlineMeeting" => true,
    "onlineMeetingProvider" => "teamsForBusiness",
    "onlineMeeting" => %{"joinUrl" => "https://teams.microsoft.com/l/meetup-join/1"},
    "organizer" => %{"emailAddress" => %{"address" => "owner@example.com"}},
    "attendees" => [
      %{
        "type" => "required",
        "status" => %{"response" => "accepted", "time" => "2026-05-21T10:00:00Z"},
        "emailAddress" => %{"address" => "guest@example.com", "name" => "Guest"}
      }
    ],
    "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
    "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
    "originalStartTimeZone" => @zone,
    "recurrence" => %{
      "pattern" => @pattern,
      "range" => %{
        "type" => "numbered",
        "startDate" => "2026-06-01",
        "numberOfOccurrences" => 30,
        "recurrenceTimeZone" => @zone
      }
    }
  }

  # Monday 2 November, after the change to winter time: 09:00 in Berlin is
  # 08:00 UTC there. Twenty-two Mondays of the series come before it.
  @slot ~U[2026-11-02 08:00:00Z]

  defp edit(changes \\ %{}, slot \\ @slot) do
    %{
      scope: :following,
      master_id: "master-1",
      slot: slot,
      start: @slot,
      end: DateTime.add(@slot, 3600),
      changes: Map.merge(%{start_time: @slot, end_time: DateTime.add(@slot, 3600)}, changes)
    }
  end

  defp with_range(range), do: put_in(@master, ["recurrence", "range"], range)

  describe "the tail" do
    test "starts at the slot on the series' wall clock, with the occurrences left" do
      assert {:ok, %{tail: tail}} = SeriesSplit.build(@master, edit())

      assert tail["start"] == %{"dateTime" => "2026-11-02T09:00:00", "timeZone" => @zone}
      assert tail["end"] == %{"dateTime" => "2026-11-02T10:00:00", "timeZone" => @zone}

      assert tail["recurrence"] == %{
               "pattern" => @pattern,
               "range" => %{
                 "type" => "numbered",
                 "startDate" => "2026-11-02",
                 "numberOfOccurrences" => 8,
                 "recurrenceTimeZone" => @zone
               }
             }
    end

    test "keeps the master's writable fields and takes the edit's changes" do
      assert {:ok, %{tail: tail}} = SeriesSplit.build(@master, edit(%{summary: "Standup"}))

      assert tail["subject"] == "Standup"
      assert tail["body"] == %{"contentType" => "html", "content" => "<p>Agenda</p>"}
      assert tail["showAs"] == "busy"

      assert tail["attendees"] == [
               %{
                 "type" => "required",
                 "emailAddress" => %{"address" => "guest@example.com", "name" => "Guest"}
               }
             ]
    end

    test "leaves out what Graph manages, and the online meeting" do
      assert {:ok, %{tail: tail}} = SeriesSplit.build(@master, edit())

      for key <-
            ~w(id iCalUId changeKey webLink createdDateTime type organizer isOnlineMeeting
               onlineMeetingProvider onlineMeeting originalStartTimeZone) do
        refute Map.has_key?(tail, key), "#{key} was copied"
      end
    end

    test "moves with the edit on the series' wall clock" do
      moved = %{start_time: ~U[2026-11-02 09:00:00Z], end_time: ~U[2026-11-02 10:00:00Z]}

      assert {:ok, %{tail: tail, head: head}} = SeriesSplit.build(@master, edit(moved))

      assert tail["start"] == %{"dateTime" => "2026-11-02T10:00:00", "timeZone" => @zone}
      assert tail["end"] == %{"dateTime" => "2026-11-02T11:00:00", "timeZone" => @zone}
      assert get_in(tail, ["recurrence", "range", "numberOfOccurrences"]) == 8
      assert get_in(head, ["recurrence", "range", "endDate"]) == "2026-11-01"
    end

    test "keeps an end date, and no end" do
      for range <- [
            %{"type" => "endDate", "startDate" => "2026-06-01", "endDate" => "2026-12-31"},
            %{"type" => "noEnd", "startDate" => "2026-06-01"}
          ] do
        assert {:ok, %{tail: tail}} = SeriesSplit.build(with_range(range), edit())

        assert get_in(tail, ["recurrence", "range"]) ==
                 Map.put(range, "startDate", "2026-11-02")
      end
    end
  end

  describe "the head" do
    test "ends on the day before the slot's date" do
      assert {:ok, %{head: head}} = SeriesSplit.build(@master, edit())

      assert head == %{
               "recurrence" => %{
                 "pattern" => @pattern,
                 "range" => %{
                   "type" => "endDate",
                   "startDate" => "2026-06-01",
                   "endDate" => "2026-11-01",
                   "recurrenceTimeZone" => @zone
                 }
               }
             }
    end
  end

  describe "what is not split" do
    test "the first occurrence is an edit of every occurrence" do
      assert SeriesSplit.build(@master, edit(%{}, ~U[2026-06-01 07:00:00Z])) ==
               :first_occurrence
    end

    test "a count over a relative pattern is refused" do
      master =
        put_in(@master, ["recurrence", "pattern"], %{
          "type" => "relativeMonthly",
          "interval" => 1,
          "daysOfWeek" => ["monday"],
          "index" => "second"
        })

      assert SeriesSplit.build(master, edit()) == {:error, :unsupported_rule}
    end

    test "a timed series in a zone that cannot be read is refused" do
      master = %{@master | "originalStartTimeZone" => "Somewhere Standard Time"}

      assert SeriesSplit.build(master, edit()) == {:error, :unreadable_timing}
    end
  end
end
