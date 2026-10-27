defmodule Tymeslot.Integrations.Calendar.Providers.CaldavCommonPartialReadTest do
  @moduledoc """
  A CalDAV connection with several calendars selected, one of which cannot be
  read: its busy time is unknown, not empty, so the live read must not answer
  the union of the calendars it could read. A calendar the server says is
  gone is the exception: it is absent, not unreadable.
  """

  use Tymeslot.MockCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Infrastructure.ProviderBreakers
  alias Tymeslot.Infrastructure.ResponseTooLargeError
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate.Outcome

  setup :set_mox_global
  setup :verify_on_exit!

  @readable "/calendars/host/readable/"
  @unreadable "/calendars/host/unreadable/"

  setup do
    ProviderBreakers.reset_all_hosts()

    client = %{
      base_url: "https://dav.example.com",
      username: "host",
      password: "secret",
      calendar_paths: [@readable, @unreadable],
      provider: :caldav
    }

    from = DateTime.utc_now()
    %{client: client, range: {from, DateTime.add(from, 7, :day)}}
  end

  defp stub_unreadable_answer(answer) do
    stub(Tymeslot.HTTPClientMock, :request, fn :report, url, _body, _headers, _opts ->
      if URI.parse(url).path == @readable,
        do: {:ok, %Req.Response{status: 207, body: multistatus("busy-on-readable")}},
        else: answer
    end)
  end

  for {label, answer} <- [
        {"a timeout", {:error, %Req.TransportError{reason: :timeout}}},
        {"a response past the read cap", {:error, %ResponseTooLargeError{}}},
        {"a refusal", {:ok, %Req.Response{status: 403, body: ""}}}
      ] do
    @answer answer

    test "#{label} on one calendar fails the read, naming it", %{client: client, range: {f, t}} do
      stub_unreadable_answer(@answer)

      assert {:error, %Outcome{succeeded: 1, failed: [%{source: @unreadable}]}} =
               CaldavCommon.get_events(client, f, t)
    end
  end

  test "a calendar the server says is gone is absent, not unreadable", %{
    client: client,
    range: {f, t}
  } do
    stub_unreadable_answer({:ok, %Req.Response{status: 404, body: ""}})

    assert {:ok, [%{uid: "busy-on-readable"}]} = CaldavCommon.get_events(client, f, t)
  end

  defp multistatus(uid) do
    start = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y%m%dT100000Z")
    finish = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y%m%dT110000Z")

    """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>#{@readable}#{uid}.ics</D:href>
        <D:propstat>
          <D:prop>
            <D:getetag>"etag-1"</D:getetag>
            <C:calendar-data>BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//Test//EN
    BEGIN:VEVENT
    UID:#{uid}
    DTSTART:#{start}
    DTEND:#{finish}
    SUMMARY:Busy
    END:VEVENT
    END:VCALENDAR</C:calendar-data>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """
  end
end
