defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsUpdateSeriesTest do
  @moduledoc """
  What reaches the server when every occurrence of a CalDAV series is edited
  from one of them: the series' resource, its master moved or renamed, put
  back under `If-Match`, and never over a copy that has moved on.
  """
  use ExUnit.Case, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  setup :verify_on_exit!

  @client %Client{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    verify_ssl: true,
    provider: :caldav
  }

  @href "/cal/weekly-sync.ics"
  @url "https://caldav.example.com/cal/weekly-sync.ics"

  @series """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:weekly-sync@example.com\r
  DTSTAMP:20260101T090000Z\r
  DTSTART;TZID=Europe/Berlin:20260105T100000\r
  DURATION:PT30M\r
  RRULE:FREQ=WEEKLY\r
  EXDATE;TZID=Europe/Berlin:20260112T100000\r
  SUMMARY:Weekly sync\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  # 19 January 2026 is winter time in Berlin (UTC+1): 10:00 moves to 11:00.
  defp occurrence(extra \\ %{}) do
    Map.merge(
      %{
        href: @href,
        key: "20260119T100000",
        timezone: "Europe/Berlin",
        document: @series,
        etag: "\"etag-1\"",
        scope: :all,
        changes: %{
          summary: "Weekly sync, later",
          start_time: ~U[2026-01-19 10:00:00Z],
          end_time: ~U[2026-01-19 10:30:00Z]
        }
      },
      extra
    )
  end

  defp update_series(occurrence),
    do: Events.update_series(@client, "/cal/", occurrence, skip_breaker: true)

  defp lines(body), do: LineFolder.unfold_lines(body)

  defp expect_put(test_pid) do
    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(test_pid, {:put, url, body, if_match(headers)})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  defp if_match(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == "if-match", do: value
    end)
  end

  describe "update_series/4 with the cached document and ETag" do
    test "PUTs the moved series under the cached ETag" do
      expect_put(self())

      assert {:ok, %{document: document}} = update_series(occurrence())

      assert_received {:put, @url, body, "\"etag-1\""}
      assert document == body

      body_lines = lines(body)
      assert "DTSTART;TZID=Europe/Berlin:20260105T110000" in body_lines
      assert "EXDATE;TZID=Europe/Berlin:20260112T110000" in body_lines
      assert "SUMMARY:Weekly sync\\, later" in body_lines
      refute Enum.any?(body_lines, &String.starts_with?(&1, "RECURRENCE-ID"))
    end

    test "an edit the series cannot take is refused before anything is written" do
      changes = %{start_time: ~D[2026-01-19], end_time: ~D[2026-01-20]}

      assert update_series(occurrence(%{changes: changes})) == {:error, :value_type_change}
    end
  end

  describe "update_series/4 when the resource moved on" do
    test "re-reads once and moves the server's copy" do
      test_pid = self()
      server_copy = String.replace(@series, "RRULE:FREQ=WEEKLY", "RRULE:FREQ=WEEKLY;COUNT=20")

      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 412, body: "Precondition Failed", headers: %{}}}
      end)

      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        send(test_pid, {:get, url})
        {:ok, %Req.Response{status: 200, body: server_copy, headers: %{"etag" => ["\"etag-2\""]}}}
      end)

      expect_put(test_pid)

      assert {:ok, %{document: document}} = update_series(occurrence())

      assert_received {:get, @url}
      assert_received {:put, @url, body, "\"etag-2\""}
      assert document == body
      assert "RRULE:FREQ=WEEKLY;COUNT=20" in lines(body)
      assert "DTSTART;TZID=Europe/Berlin:20260105T110000" in lines(body)
    end

    test "a series gone from the server is not found" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: "", headers: %{}}}
      end)

      assert update_series(occurrence(%{document: nil, etag: nil})) == {:error, :not_found}
    end
  end

  describe "editing every occurrence through the provider" do
    test "CaldavCommon.update_event/3 routes an :occurrence of scope :all to the master" do
      expect_put(self())

      assert {:ok, %{document: _document}} =
               CaldavCommon.update_event(
                 @client,
                 "weekly-sync@example.com",
                 %{occurrence: occurrence(), summary: "Not read"},
                 skip_breaker: true
               )

      assert_received {:put, @url, body, "\"etag-1\""}
      body_lines = lines(body)
      assert "DTSTART;TZID=Europe/Berlin:20260105T110000" in body_lines
      # Not an override of the one occurrence.
      refute Enum.any?(body_lines, &String.starts_with?(&1, "RECURRENCE-ID"))
      refute "SUMMARY:Not read" in body_lines
    end
  end
end
