defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsUpdateOccurrenceTest do
  @moduledoc """
  What reaches the server when one occurrence of a CalDAV series is edited.

  A series is one resource, so an edit of one occurrence is a rewrite of that
  resource: the occurrence's override `VEVENT` is written, or made from the
  master, and the rest goes back untouched. Like an occurrence delete, the
  rewrite lands only on the copy the server holds, never on a stale one.
  """
  use ExUnit.Case, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter

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
  @recurrence_id "RECURRENCE-ID;TZID=Europe/Berlin:20260119T100000"
  # 19 January 2026 is winter time in Berlin (UTC+1): 15:00 local.
  @new_start "DTSTART;TZID=Europe/Berlin:20260119T150000"

  @master """
  BEGIN:VEVENT
  UID:weekly-sync@example.com
  DTSTAMP:20260101T090000Z
  DTSTART;TZID=Europe/Berlin:20260105T100000
  DURATION:PT30M
  RRULE:FREQ=WEEKLY
  SUMMARY:Weekly sync
  END:VEVENT
  """

  defp calendar(body) do
    document = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Example Corp//Calendar 1.0//EN
    #{body}END:VCALENDAR
    """

    String.replace(document, ~r/\r?\n/, "\r\n")
  end

  defp series, do: calendar(@master)

  defp occurrence(extra \\ %{}) do
    Map.merge(
      %{
        href: @href,
        key: "20260119T100000",
        timezone: "Europe/Berlin",
        document: series(),
        etag: "\"etag-1\"",
        changes: %{
          summary: "Weekly sync, afternoon",
          start_time: ~U[2026-01-19 14:00:00Z],
          end_time: ~U[2026-01-19 14:30:00Z]
        }
      },
      extra
    )
  end

  defp update_occurrence(occurrence),
    do: Events.update_occurrence(@client, "/cal/", occurrence, skip_breaker: true)

  defp lines(body), do: LineFolder.unfold_lines(body)

  defp ok_response, do: {:ok, %Req.Response{status: 204, body: "", headers: %{}}}

  defp expect_put(test_pid) do
    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(test_pid, {:put, url, body, if_match(headers)})
      ok_response()
    end)
  end

  defp expect_get(test_pid, body, etag) do
    expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
      send(test_pid, {:get, url})
      {:ok, %Req.Response{status: 200, body: body, headers: %{"etag" => [etag]}}}
    end)
  end

  defp if_match(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == "if-match", do: value
    end)
  end

  describe "update_occurrence/4 with the cached document and ETag" do
    test "PUTs the series with the occurrence's override under the cached ETag" do
      expect_put(self())

      assert {:ok, %{document: document}} = update_occurrence(occurrence())

      assert_received {:put, @url, body, "\"etag-1\""}
      assert document == body

      body_lines = lines(body)
      assert @recurrence_id in body_lines
      assert @new_start in body_lines
      assert "SUMMARY:Weekly sync\\, afternoon" in body_lines
      # The master still carries the series, unchanged.
      assert "DTSTART;TZID=Europe/Berlin:20260105T100000" in body_lines
      assert "RRULE:FREQ=WEEKLY" in body_lines
      assert "SUMMARY:Weekly sync" in body_lines
    end

    test "an edit the series cannot take is refused before anything is written" do
      changes = %{start_time: ~D[2026-01-19], end_time: ~D[2026-01-20]}

      assert update_occurrence(occurrence(%{changes: changes})) ==
               {:error, :value_type_change}
    end
  end

  describe "update_occurrence/4 when the resource moved on" do
    test "re-reads once and writes the override into the server's copy" do
      test_pid = self()
      server_copy = String.replace(series(), "RRULE:FREQ=WEEKLY", "RRULE:FREQ=WEEKLY;COUNT=20")

      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 412, body: "Precondition Failed", headers: %{}}}
      end)

      expect_get(test_pid, server_copy, "\"etag-2\"")
      expect_put(test_pid)

      assert {:ok, %{document: document}} = update_occurrence(occurrence())

      assert_received {:get, @url}
      assert_received {:put, @url, body, "\"etag-2\""}
      assert "RRULE:FREQ=WEEKLY;COUNT=20" in lines(body)
      assert @new_start in lines(body)
      assert document == body
    end

    test "a series gone from the server is not found" do
      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: "", headers: %{}}}
      end)

      assert update_occurrence(occurrence(%{document: nil, etag: nil})) == {:error, :not_found}
    end
  end

  describe "editing an occurrence through the provider" do
    test "CaldavCommon.update_event/3 routes an :occurrence to the rewrite" do
      expect_put(self())

      assert {:ok, %{document: document}} =
               CaldavCommon.update_event(
                 @client,
                 "weekly-sync@example.com",
                 %{occurrence: occurrence(), summary: "Not read"},
                 skip_breaker: true
               )

      assert_received {:put, @url, body, "\"etag-1\""}
      assert @new_start in lines(body)
      refute "SUMMARY:Not read" in lines(body)
      assert document == body
    end

    test "the provider adapter passes the new document through" do
      expect_put(self())

      adapter_client = %{provider_type: :caldav, provider_module: CalDAVProvider, client: @client}

      assert {:ok, %{document: document}} =
               ProviderAdapter.update_event(adapter_client, "weekly-sync@example.com", %{
                 occurrence: occurrence()
               })

      assert @new_start in lines(document)
    end
  end
end
