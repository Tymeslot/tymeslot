defmodule TymeslotWeb.Dashboard.IcsImportFlowTest do
  @moduledoc """
  The surface-neutral half of the calendar's `.ics` import, called by both
  calendars: the upload it registers, the plan and summary of a file, and
  what each refusal and each outcome says. Reading an uploaded file
  (`consume/1`) needs a live upload and is covered end to end by the old
  calendar's `ics_import_liveview_test.exs` (and by the new surface's import
  test from Task 8).
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias TymeslotWeb.Dashboard.IcsImportFlow

  @three_events """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:one@example.com\r
  SUMMARY:Dentist\r
  DTSTART:20261105T090000Z\r
  DTEND:20261105T093000Z\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:two@example.com\r
  SUMMARY:Standup\r
  DTSTART:20261102T090000Z\r
  DTEND:20261102T091500Z\r
  RRULE:FREQ=WEEKLY;COUNT=4\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:three@example.com\r
  SUMMARY:Called off\r
  STATUS:CANCELLED\r
  DTSTART:20261106T090000Z\r
  DTEND:20261106T100000Z\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  describe "the upload" do
    test "is one .ics file of up to 5 MB, uploaded at once and reported to the caller's callback" do
      progress = fn _name, _entry, socket -> {:noreply, socket} end
      options = IcsImportFlow.upload_options(progress)

      assert IcsImportFlow.upload_name() == :ics_file
      assert options[:accept] == ~w(.ics)
      assert options[:max_entries] == 1
      assert options[:max_file_size] == 5_000_000
      assert options[:auto_upload] == true
      assert options[:progress] == progress
    end
  end

  describe "planning a file" do
    test "counts its events, the repeating ones and the cancelled ones left out" do
      assert {:ok, plan} = IcsImportFlow.plan(@three_events, "Etc/UTC")
      assert IcsImportFlow.summary(plan) == %{events: 2, series: 1, cancelled: 1}
    end

    test "refuses a file that is not a calendar" do
      assert IcsImportFlow.plan("just some text", "Etc/UTC") == {:error, :invalid_file}
    end
  end

  describe "refusals" do
    test "name the upload's limit or the accepted type" do
      assert IcsImportFlow.upload_error(:too_large) ==
               "The file is too large. Files up to 5 MB can be imported."

      assert IcsImportFlow.upload_error(:not_accepted) ==
               "Only .ics calendar files can be imported."

      assert IcsImportFlow.upload_error(:too_many_files) ==
               "The file could not be uploaded. Please try again."
    end

    test "say why a file could not be planned" do
      assert IcsImportFlow.plan_error(:invalid_file) ==
               "This file could not be read as a calendar. Please choose an .ics file."

      assert IcsImportFlow.plan_error(:no_events) == "This file contains no events to import."

      assert IcsImportFlow.plan_error(:too_many_events) ==
               "This file contains more than 1000 events. Please split it into smaller files."

      assert IcsImportFlow.plan_error(:too_large) == IcsImportFlow.upload_error(:too_large)
    end

    test "say why an import could not start" do
      assert IcsImportFlow.busy_message() ==
               "An import is still running. Please wait for it to finish before importing another file."

      assert IcsImportFlow.start_error(:rate_limited) ==
               "Too many imports. Please wait a while before importing another file."

      assert IcsImportFlow.start_error(:invalid_calendar) == "Invalid calendar selected"
    end
  end

  describe "the result" do
    test "is information when every event was written" do
      assert IcsImportFlow.result_flash({:ok, summary(%{total: 3, created: 3})}) ==
               {:info, "Imported 3 events."}
    end

    test "is an error naming the reason when the calendar stopped the import before any write" do
      result = summary(%{total: 3, failed: 3, failed_titles: ["Dentist"], halted: :unauthorized})

      assert IcsImportFlow.result_flash({:ok, result}) ==
               {:error, "The import stopped because your calendar needs to be reconnected."}
    end

    test "is a warning naming the written events, the failed titles and the halt" do
      result =
        summary(%{
          total: 4,
          created: 2,
          failed: 1,
          failed_titles: ["Dentist"],
          halted: :unavailable
        })

      assert IcsImportFlow.result_flash({:ok, result}) ==
               {:warning,
                "Imported 2 events. 1 event could not be imported. (Dentist) The import stopped because your calendar is not responding. Please try again later."}
    end

    test "says an import is already running, or that it could not finish" do
      assert IcsImportFlow.result_flash({:error, :already_running}) ==
               {:error, IcsImportFlow.busy_message()}

      assert IcsImportFlow.result_flash({:error, :failed}) ==
               {:error,
                "The import could not be finished. Some of its events may already be in your calendar."}
    end
  end

  # An import summary with nothing written, failed or refused but `counts`.
  defp summary(counts) do
    Map.merge(
      %{
        total: 0,
        created: 0,
        failed: 0,
        failed_titles: [],
        exclusions_dropped: 0,
        rules_refused: 0,
        month_end_refused: 0,
        halted: nil
      },
      counts
    )
  end
end
