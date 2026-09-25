defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsSplitSeriesTest do
  @moduledoc """
  What reaches the server when one occurrence of a CalDAV series and every
  following one are edited: the following occurrences created as a new
  resource beside the series, then the series ended before them under
  `If-Match`, and the new resource deleted again if the series cannot be
  ended, so no occurrence is ever shown twice.
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

  # The series lives in a collection other than the integration's first.
  @href "/work/weekly-sync.ics"
  @url "https://caldav.example.com/work/weekly-sync.ics"

  @series """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:weekly-sync@example.com\r
  DTSTAMP:20260101T090000Z\r
  DTSTART;TZID=Europe/Berlin:20260105T100000\r
  DURATION:PT30M\r
  RRULE:FREQ=WEEKLY;COUNT=10\r
  SUMMARY:Weekly sync\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  defp occurrence(extra \\ %{}) do
    Map.merge(
      %{
        href: @href,
        key: "20260126T100000",
        timezone: "Europe/Berlin",
        document: @series,
        etag: "\"etag-1\"",
        scope: :following,
        changes: %{summary: "Weekly sync, renamed"}
      },
      extra
    )
  end

  defp split_series(occurrence),
    do: Events.split_series(@client, "/cal/", occurrence, skip_breaker: true)

  defp lines(body), do: LineFolder.unfold_lines(body)

  defp header(headers, wanted) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == wanted, do: value
    end)
  end

  # Answers every PUT with `status`, reporting it to the test in order.
  defp expect_put(status) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(
        test_pid,
        {:put, url, body, header(headers, "if-match"), header(headers, "if-none-match")}
      )

      {:ok, %Req.Response{status: status, body: "", headers: %{}}}
    end)
  end

  defp expect_get(body, etag) do
    expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: body, headers: %{"etag" => [etag]}}}
    end)
  end

  defp tail_url(uid), do: "https://caldav.example.com/work/#{uid}.ics"

  describe "split_series/4" do
    test "creates the tail beside the series, then ends the series under its ETag" do
      expect_put(201)
      expect_put(204)

      assert {:ok, %{document: head, tail: %{uid: uid, href: tail_href, document: tail}}} =
               split_series(occurrence())

      assert_received {:put, tail_put_url, tail_body, nil, "*"}
      assert tail_put_url == tail_url(uid)
      assert tail_href == "/work/#{uid}.ics"
      assert tail_body == tail
      assert "UID:#{uid}" in lines(tail_body)
      assert "DTSTART;TZID=Europe/Berlin:20260126T100000" in lines(tail_body)
      assert "RRULE:FREQ=WEEKLY;COUNT=7" in lines(tail_body)
      assert "SUMMARY:Weekly sync\\, renamed" in lines(tail_body)

      assert_received {:put, @url, head_body, "\"etag-1\"", nil}
      assert head_body == head
      assert "RRULE:FREQ=WEEKLY;UNTIL=20260126T085959Z" in lines(head_body)
      assert "SUMMARY:Weekly sync" in lines(head_body)
    end

    test "a series changed meanwhile is re-read once and the server's copy is ended" do
      server_copy = String.replace(@series, "SUMMARY:Weekly sync", "SUMMARY:Changed elsewhere")

      expect_put(201)
      expect_put(412)
      expect_get(server_copy, "\"etag-2\"")
      expect_put(204)

      assert {:ok, %{document: head}} = split_series(occurrence())

      assert_received {:put, _tail_url, _tail, nil, "*"}
      assert_received {:put, @url, _stale_head, "\"etag-1\"", nil}
      assert_received {:put, @url, ^head, "\"etag-2\"", nil}
      assert "SUMMARY:Changed elsewhere" in lines(head)
      assert "RRULE:FREQ=WEEKLY;UNTIL=20260126T085959Z" in lines(head)
    end

    test "a series that cannot be ended has its tail deleted again, and the error reported" do
      test_pid = self()

      expect_put(201)
      expect_put(412)
      expect_get(@series, "\"etag-2\"")
      expect_put(412)

      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        send(test_pid, {:delete, url})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert split_series(occurrence()) == {:error, :precondition_failed}

      assert_received {:put, tail_put_url, _tail, nil, "*"}
      assert_received {:delete, ^tail_put_url}
    end

    test "a tail that cannot be created leaves the series alone" do
      # Under `verify_on_exit!` a second PUT, or a DELETE, would fail the test.
      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, _reason} = split_series(occurrence())
    end

    test "an edit of the first occurrence is written to the whole series" do
      expect_put(204)

      assert {:ok, %{document: document} = answer} =
               split_series(occurrence(%{key: "20260105T100000"}))

      refute Map.has_key?(answer, :tail)
      assert_received {:put, @url, ^document, "\"etag-1\"", nil}
      assert "SUMMARY:Weekly sync\\, renamed" in lines(document)
      assert "RRULE:FREQ=WEEKLY;COUNT=10" in lines(document)
    end

    test "an edit the tail cannot take is refused before anything is written" do
      changes = %{start_time: ~D[2026-01-26], end_time: ~D[2026-01-27]}

      assert split_series(occurrence(%{changes: changes})) == {:error, :value_type_change}
    end
  end

  describe "through the provider" do
    test "CaldavCommon.update_event/3 routes an :occurrence of scope :following to a split" do
      expect_put(201)
      expect_put(204)

      assert {:ok, %{document: _head, tail: %{uid: _uid}}} =
               CaldavCommon.update_event(
                 @client,
                 "weekly-sync@example.com",
                 %{occurrence: occurrence(), summary: "Not read"},
                 skip_breaker: true
               )

      assert_received {:put, _tail_url, _tail, nil, "*"}
      assert_received {:put, @url, _head, "\"etag-1\"", nil}
    end
  end
end
