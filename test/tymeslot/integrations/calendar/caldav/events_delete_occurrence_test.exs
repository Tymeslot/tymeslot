defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsDeleteOccurrenceTest do
  @moduledoc """
  What reaches the server when one occurrence of a CalDAV series is deleted.

  A series is one resource, a master `VEVENT` plus a `VEVENT` per modified
  occurrence, so deleting one occurrence is a rewrite of that resource rather
  than a DELETE: the master gains an `EXDATE` and any override standing in the
  slot goes. The rewrite has to land on the copy the server holds, never on a
  stale one, or it would revert whatever changed there in the meantime.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.CalDAV.Provider, as: CalDAVProvider
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
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
  @new_exdate "EXDATE;TZID=Europe/Berlin:20260119T100000"

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

  @override """
  BEGIN:VEVENT
  UID:weekly-sync@example.com
  DTSTAMP:20260101T090000Z
  RECURRENCE-ID;TZID=Europe/Berlin:20260112T100000
  DTSTART;TZID=Europe/Berlin:20260112T150000
  DURATION:PT30M
  SUMMARY:Weekly sync, moved
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

  defp series, do: calendar(@master <> @override)

  defp occurrence(extra \\ %{}) do
    Map.merge(
      %{
        href: @href,
        key: "20260119T100000",
        timezone: "Europe/Berlin",
        document: series(),
        etag: "\"etag-1\""
      },
      extra
    )
  end

  defp delete_occurrence(occurrence),
    do: Events.delete_occurrence(@client, "/cal/", occurrence, skip_breaker: true)

  defp lines(body), do: LineFolder.unfold_lines(body)

  defp ok_response(headers \\ %{}),
    do: {:ok, %Req.Response{status: 204, body: "", headers: headers}}

  defp expect_put(test_pid, response_fun) do
    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(test_pid, {:put, url, body, if_match(headers)})
      response_fun.()
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

  describe "delete_occurrence/4 with the cached document and ETag" do
    test "PUTs the series with the new EXDATE under the cached ETag, without reading" do
      expect_put(self(), &ok_response/0)

      assert {:ok, %{document: document}} = delete_occurrence(occurrence())

      assert_received {:put, @url, body, "\"etag-1\""}
      assert @new_exdate in lines(body)
      # The override for another slot is untouched.
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260112T100000" in lines(body)
      assert document == body
    end
  end

  describe "delete_occurrence/4 with no cached document" do
    test "reads the server's copy and PUTs it back under the ETag it came with" do
      test_pid = self()
      expect_get(test_pid, series(), "\"etag-live\"")
      expect_put(test_pid, &ok_response/0)

      assert {:ok, %{document: document}} =
               delete_occurrence(occurrence(%{document: nil, etag: nil}))

      assert_received {:get, @url}
      assert_received {:put, @url, body, "\"etag-live\""}
      assert @new_exdate in lines(body)
      assert document == body
    end
  end

  describe "delete_occurrence/4 when the resource moved on" do
    test "re-reads once and applies the exclusion to the server's copy" do
      test_pid = self()
      server_copy = String.replace(series(), "SUMMARY:Weekly sync\r\n", "SUMMARY:Renamed\r\n")

      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 412, body: "Precondition Failed", headers: %{}}}
      end)

      expect_get(test_pid, server_copy, "\"etag-2\"")
      expect_put(test_pid, &ok_response/0)

      assert {:ok, %{document: document}} = delete_occurrence(occurrence())

      assert_received {:put, @url, body, "\"etag-2\""}
      # The change made on the server survives, and the occurrence still goes.
      assert "SUMMARY:Renamed" in lines(body)
      assert @new_exdate in lines(body)
      assert document == body
    end

    test "a second rejection is an error, with no third PUT" do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, 2, fn _url, _body, _headers, _opts ->
        send(test_pid, :put)
        {:ok, %Req.Response{status: 412, body: "Precondition Failed", headers: %{}}}
      end)

      expect_get(test_pid, series(), "\"etag-2\"")

      assert {:error, :precondition_failed} = delete_occurrence(occurrence())

      assert_received :put
      assert_received :put
      refute_received :put
    end
  end

  describe "delete_occurrence/4 when nothing of the series is left" do
    test "deletes the resource that held only the occurrence's override" do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        send(test_pid, {:delete, url})
        ok_response()
      end)

      only_override = %{document: calendar(@override), key: "20260112T100000"}

      assert {:ok, %{document: nil}} = delete_occurrence(occurrence(only_override))
      assert_received {:delete, @url}
    end
  end

  describe "deleting an occurrence through the provider" do
    test "CaldavCommon.delete_event/3 routes an :occurrence to the rewrite" do
      expect_put(self(), &ok_response/0)

      assert {:ok, %{document: document}} =
               CaldavCommon.delete_event(@client, "weekly-sync@example.com",
                 occurrence: occurrence(),
                 skip_breaker: true
               )

      assert_received {:put, @url, body, "\"etag-1\""}
      assert @new_exdate in lines(body)
      assert document == body
    end

    test "the provider adapter passes the new document through" do
      expect_put(self(), &ok_response/0)

      adapter_client = %{
        provider_type: :caldav,
        provider_module: CalDAVProvider,
        client: @client
      }

      assert {:ok, %{document: document}} =
               ProviderAdapter.delete_event(adapter_client, "weekly-sync@example.com",
                 occurrence: occurrence(),
                 skip_breaker: true
               )

      assert @new_exdate in lines(document)
    end
  end

  describe "deleting an occurrence through the calendar context" do
    setup do
      previous_module = Application.get_env(:tymeslot, :calendar_module)
      Application.put_env(:tymeslot, :calendar_module, Operations)

      on_exit(fn ->
        if previous_module do
          Application.put_env(:tymeslot, :calendar_module, previous_module)
        else
          Application.delete_env(:tymeslot, :calendar_module)
        end
      end)

      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      %{user: user, integration: integration}
    end

    test "delete_event_and_reconcile/4 answers with the series' new document", %{
      user: user,
      integration: integration
    } do
      expect_put(self(), &ok_response/0)

      assert {:ok, result} =
               CalendarEvents.delete_event_and_reconcile(
                 "weekly-sync@example.com",
                 @href,
                 {integration.id, user.id},
                 occurrence: occurrence(),
                 provider_event_id: @href
               )

      assert_received {:put, @url, body, "\"etag-1\""}
      assert result.document == body
      assert @new_exdate in lines(result.document)
      assert result.uid == "weekly-sync@example.com"
      assert result.integration_id == integration.id
    end
  end
end
