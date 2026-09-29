defmodule Tymeslot.Test.CalDAVAccountStub do
  @moduledoc """
  Plays a CalDAV account behind `Tymeslot.HTTPClientMock.request/5`, for the
  search of every calendar of an account for one event
  (`CaldavCommon.find_moved_event/2`): calendar discovery's PROPFIND, and the
  calendar-query REPORT by UID each calendar is asked.

  `answer/4` is meant for a test's own `request/5` stub, so that the test
  keeps answering its other requests (a Talk server's DELETE, say):

      stub(HTTPClientMock, :request, fn
        :delete, url, _body, _headers, _opts -> ...
        method, url, body, _headers, _opts -> CalDAVAccountStub.answer(account, method, url, body)
      end)

  The account is a map:

    * `:calendars`: the collection paths discovery finds.
    * `:resources`: `%{path => [{href, ical}]}`, the event resources each
      calendar holds.
    * `:failing`: statuses by path, for a REPORT, or for discovery
      (`:discovery`), that the server fails with.
    * `:notify`: a pid told `{:dav_report, path, uid}` of every REPORT.

  A REPORT matches the UID as a real server's `text-match` does, as a
  substring, so that the caller's own exact match is what is tested.
  """

  @spec answer(map(), atom(), String.t(), String.t()) :: {:ok, Req.Response.t()}
  def answer(account, :propfind, _url, _body) do
    case get_in(account, [:failing, :discovery]) do
      nil -> multistatus(Enum.map(Map.get(account, :calendars, []), &calendar_response/1))
      status -> {:ok, %Req.Response{status: status, body: ""}}
    end
  end

  def answer(account, :report, url, body) do
    path = URI.parse(url).path
    [_match, uid] = Regex.run(~r{<c:text-match[^>]*>([^<]*)</c:text-match>}, body)

    if pid = account[:notify], do: send(pid, {:dav_report, path, uid})

    case get_in(account, [:failing, path]) do
      nil ->
        account
        |> Map.get(:resources, %{})
        |> Map.get(path, [])
        |> Enum.filter(fn {_href, ical} -> ical =~ "UID:" <> uid end)
        |> Enum.map(&event_response/1)
        |> multistatus()

      status ->
        {:ok, %Req.Response{status: status, body: ""}}
    end
  end

  defp multistatus(responses),
    do:
      {:ok,
       %Req.Response{
         status: 207,
         body: """
         <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
         #{Enum.join(responses)}
         </D:multistatus>
         """
       }}

  defp calendar_response(path),
    do: """
    <D:response>
      <D:href>#{path}</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>#{path}</D:displayname>
          <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
    """

  defp event_response({href, ical}),
    do: """
    <D:response>
      <D:href>#{href}</D:href>
      <D:propstat>
        <D:prop>
          <D:getetag>"etag-1"</D:getetag>
          <C:calendar-data><![CDATA[#{ical}]]></C:calendar-data>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
    """
end
