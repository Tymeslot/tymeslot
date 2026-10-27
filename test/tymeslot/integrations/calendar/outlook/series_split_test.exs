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

  describe "the tail, moved to another day" do
    test "takes the end date along, so the last occurrence stays" do
      range = %{"type" => "endDate", "startDate" => "2026-06-01", "endDate" => "2026-12-28"}
      moved = %{start_time: ~U[2026-11-03 08:00:00Z], end_time: ~U[2026-11-03 09:00:00Z]}

      assert {:ok, %{tail: tail}} = SeriesSplit.build(with_range(range), edit(moved))

      assert get_in(tail, ["recurrence", "range"]) ==
               %{range | "startDate" => "2026-11-03", "endDate" => "2026-12-29"}
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

  # A Monday-and-Wednesday series created through the API on Tuesday 2 June:
  # Graph keeps the master's start on the Tuesday, but its first occurrence
  # is Wednesday 3 June, and `numberOfOccurrences` counts pattern dates only
  # (3, 8, 10, 15 June, ...), unlike RFC 5545, where the start always counts.
  @off_pattern_master @master
                      |> Map.merge(%{
                        "start" => %{
                          "dateTime" => "2026-06-02T07:00:00.0000000",
                          "timeZone" => "UTC"
                        },
                        "end" => %{
                          "dateTime" => "2026-06-02T08:00:00.0000000",
                          "timeZone" => "UTC"
                        }
                      })
                      |> put_in(["recurrence", "pattern", "daysOfWeek"], ["monday", "wednesday"])
                      |> put_in(["recurrence", "range"], %{
                        "type" => "numbered",
                        "startDate" => "2026-06-02",
                        "numberOfOccurrences" => 10,
                        "recurrenceTimeZone" => @zone
                      })

  describe "a series whose start is off its pattern" do
    test "counts only pattern dates before the slot, so the tail keeps every occurrence" do
      # Monday 15 June: three occurrences (3, 8 and 10 June) come before it.
      slot = ~U[2026-06-15 07:00:00Z]

      assert {:ok, %{tail: tail}} = SeriesSplit.build(@off_pattern_master, edit(%{}, slot))

      assert get_in(tail, ["recurrence", "range", "numberOfOccurrences"]) == 7
    end

    test "at its first pattern date is an edit of every occurrence" do
      assert SeriesSplit.build(@off_pattern_master, edit(%{}, ~U[2026-06-03 07:00:00Z])) ==
               :first_occurrence
    end
  end

  defp late_start_master(pattern, date) do
    pattern
    |> off_day_master()
    |> Map.merge(%{
      "start" => %{"dateTime" => "#{date}T08:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "#{date}T09:00:00.0000000", "timeZone" => "UTC"}
    })
    |> put_in(["recurrence", "range", "startDate"], date)
  end

  # An API-created absolute pattern on the 10th whose master starts on
  # Friday 5 June: Graph's first occurrence is the 10th, and
  # `numberOfOccurrences` counts the 10ths only.
  defp off_day_master(pattern) do
    @master
    |> Map.merge(%{
      "start" => %{"dateTime" => "2026-06-05T07:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-06-05T08:00:00.0000000", "timeZone" => "UTC"}
    })
    |> put_in(["recurrence", "pattern"], pattern)
    |> put_in(["recurrence", "range"], %{
      "type" => "numbered",
      "startDate" => "2026-06-05",
      "numberOfOccurrences" => 10,
      "recurrenceTimeZone" => @zone
    })
  end

  @monthly_on_the_10th %{"type" => "absoluteMonthly", "interval" => 1, "dayOfMonth" => 10}

  @yearly_on_10_june %{
    "type" => "absoluteYearly",
    "interval" => 1,
    "dayOfMonth" => 10,
    "month" => 6
  }

  describe "an absolute monthly series whose start is off its day of the month" do
    test "counts only the 10ths before the slot" do
      # 10 August: 10 June and 10 July come before it.
      master = off_day_master(@monthly_on_the_10th)

      assert {:ok, %{tail: tail}} = SeriesSplit.build(master, edit(%{}, ~U[2026-08-10 07:00:00Z]))

      assert get_in(tail, ["recurrence", "range", "numberOfOccurrences"]) == 8
    end

    test "at its first 10th is an edit of every occurrence" do
      master = off_day_master(@monthly_on_the_10th)

      assert SeriesSplit.build(master, edit(%{}, ~U[2026-06-10 07:00:00Z])) ==
               :first_occurrence
    end
  end

  describe "an absolute yearly series whose start is off its date" do
    test "counts only the 10 Junes before the slot" do
      # 10 June 2028: 10 June 2026 and 2027 come before it.
      master = off_day_master(@yearly_on_10_june)

      assert {:ok, %{tail: tail}} = SeriesSplit.build(master, edit(%{}, ~U[2028-06-10 07:00:00Z]))

      assert get_in(tail, ["recurrence", "range", "numberOfOccurrences"]) == 8
    end

    test "at its first 10 June is an edit of every occurrence" do
      master = off_day_master(@yearly_on_10_june)

      assert SeriesSplit.build(master, edit(%{}, ~U[2026-06-10 07:00:00Z])) ==
               :first_occurrence
    end
  end

  # A start on a day some months lack: an RRULE stepping on that day skips
  # those months, while Graph has a pattern date in every period.
  describe "an absolute series whose start falls on a day some months lack" do
    test "a monthly one counts a 10th in every month since the start" do
      # From 31 January, 10 June: the 10ths of February to May come before it.
      master = late_start_master(@monthly_on_the_10th, "2027-01-31")

      assert {:ok, %{tail: tail}} = SeriesSplit.build(master, edit(%{}, ~U[2027-06-10 07:00:00Z]))

      assert get_in(tail, ["recurrence", "range", "numberOfOccurrences"]) == 6
    end

    test "a yearly one counts a 10 June in every year since the start" do
      # From 29 February 2028, 10 June 2031: 2028, 2029 and 2030 come before it.
      master = late_start_master(@yearly_on_10_june, "2028-02-29")

      assert {:ok, %{tail: tail}} = SeriesSplit.build(master, edit(%{}, ~U[2031-06-10 07:00:00Z]))

      assert get_in(tail, ["recurrence", "range", "numberOfOccurrences"]) == 7
    end
  end

  describe "a relative monthly series" do
    # The first Monday of every month, from Monday 1 June; 2 November is
    # the first Monday of November.
    @first_monday %{
      "type" => "relativeMonthly",
      "interval" => 1,
      "daysOfWeek" => ["monday"],
      "index" => "first",
      "firstDayOfWeek" => "sunday"
    }

    test "with no end is split, the tail repeating as the series did" do
      master =
        @master
        |> put_in(["recurrence", "pattern"], @first_monday)
        |> put_in(["recurrence", "range"], %{"type" => "noEnd", "startDate" => "2026-06-01"})

      assert {:ok, %{tail: tail, head: head}} = SeriesSplit.build(master, edit())

      assert tail["recurrence"]["pattern"] == @first_monday
      assert tail["recurrence"]["range"] == %{"type" => "noEnd", "startDate" => "2026-11-02"}
      assert head["recurrence"]["range"]["endDate"] == "2026-11-01"
    end

    # The occurrences before the split are not counted over a counted
    # weekday (`RecurrenceExpander.countable?/1`).
    test "with a number of occurrences is refused" do
      master = put_in(@master, ["recurrence", "pattern"], @first_monday)

      assert SeriesSplit.build(master, edit()) == {:error, :unsupported_rule}
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
