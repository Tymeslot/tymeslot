defmodule Tymeslot.Test.GoogleMeetFake do
  @moduledoc """
  Plays Google Calendar and the Google Meet API behind
  `Tymeslot.HTTPClientMock.request/5`, for a test that books through the
  real Google Calendar client.

  The fake keeps the events it is given, per calendar, so a read sees what
  the writes before it left. As Google does, a create asking for a Meet
  (`conferenceDataVersion=1` with a `createRequest`) is answered while the
  Meet is still being made, and the Meet's link is there on the next read. A
  write without `conferenceDataVersion=1` leaves the event's conference as
  it is, and times come back with their offset in the event's time zone. A
  calendar's event list, read for availability, is empty.
  The Meet API makes the space `space-1`, and finds no call to end in any
  space.

  Options of `start/1`: `refuse_conference: true` refuses a Meet the way a
  calendar that allows no Meet conferences does, by refusing the whole
  create; `refuse_events: true` refuses every create for a reason that is not
  its conference; `meet_pending: true` never finishes making it;
  `on_conference_removal: fun` calls `fun` as a write that takes an event's
  conference off arrives, before Google applies it.

  Requests are reported to the test that called `start/1`; `requests/0`
  collects them. The organiser's calendar is `calendar_id/0`, a Meet Google
  makes for an event has the link `meet_url/0`, and a Meet space the Meet API
  makes has `space_url/0`.
  """

  import Mox

  @calendar_id "organiser@example.com"
  @meet_url "https://meet.google.com/abc-defg-hij"
  @space_url "https://meet.google.com/xyz-uvwx-rst"

  @doc "The organiser's booking calendar."
  @spec calendar_id() :: String.t()
  def calendar_id, do: @calendar_id

  @doc "The link of the Meet Google makes for an event."
  @spec meet_url() :: String.t()
  def meet_url, do: @meet_url

  @doc "The link of the Meet space the Meet API makes."
  @spec space_url() :: String.t()
  def space_url, do: @space_url

  @doc "Answers every Google request of the calling test; see the module doc."
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    test_pid = self()
    refuse_conference? = Keyword.get(opts, :refuse_conference, false)
    meet_pending? = Keyword.get(opts, :meet_pending, false)
    refuse_events? = Keyword.get(opts, :refuse_events, false)
    {:ok, events} = Agent.start_link(fn -> %{} end)
    on_conference_removal = Keyword.get(opts, :on_conference_removal, fn -> :ok end)

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      uri = URI.parse(url)
      sent = if is_binary(body) and body != "", do: Jason.decode!(body), else: %{}
      send(test_pid, {:google, method, uri, sent})

      case {method, uri.host} do
        {:get, "www.googleapis.com"} ->
          read_event(events, uri, meet_pending?)

        {:post, "www.googleapis.com"}
        when refuse_conference? and is_map_key(sent, "conferenceData") ->
          bad_request(~s({"error":{"message":"Invalid conference type value."}}))

        {:post, "www.googleapis.com"} when refuse_events? ->
          bad_request(
            ~s({"error":{"message":"Bad Request","errors":[{"reason":"invalid","message":"Invalid attendee email."}]}})
          )

        {:put, "www.googleapis.com"} ->
          put_event(events, uri, sent, on_conference_removal)

        {:delete, "www.googleapis.com"} ->
          delete_event(events, uri)

        {_write, "www.googleapis.com"} ->
          write_event(events, method, uri, sent)

        {:post, "meet.googleapis.com"} ->
          meet_api(uri)

        _other ->
          {:ok, %Req.Response{status: 404, body: ~s({"error":{"message":"unexpected"}})}}
      end
    end)

    :ok
  end

  @doc """
  The calendar a request addresses. Events are kept per calendar, as Google
  keeps them: an event read or written in another calendar than the one it
  was made in is not found. `primary` is the account's primary calendar.
  """
  @spec calendar_of(URI.t()) :: String.t()
  def calendar_of(uri) do
    case uri.path |> String.split("/") |> Enum.drop_while(&(&1 != "calendars")) do
      ["calendars", "primary" | _rest] -> @calendar_id
      ["calendars", calendar | _rest] -> URI.decode(calendar)
    end
  end

  defp event_key(uri, id), do: {calendar_of(uri), id}

  defp read_event(events, uri, meet_pending?) do
    case uri.path |> String.split("/") |> List.last() do
      "events" -> {:ok, %Req.Response{status: 200, body: ~s({"items":[]})}}
      id -> read_one_event(events, event_key(uri, id), meet_pending?)
    end
  end

  defp read_one_event(events, key, meet_pending?) do
    case Agent.get(events, &Map.get(&1, key)) do
      nil -> {:ok, %Req.Response{status: 404, body: ~s({"error":{"message":"Not Found"}})}}
      event when meet_pending? -> {:ok, %Req.Response{status: 200, body: Jason.encode!(event)}}
      event -> {:ok, %Req.Response{status: 200, body: Jason.encode!(made_meet(event))}}
    end
  end

  defp bad_request(body), do: {:ok, %Req.Response{status: 400, body: body}}

  defp put_event(events, uri, sent, on_conference_removal) do
    if URI.decode_query(uri.query || "")["conferenceDataVersion"] == "1" and
         not is_map_key(sent, "conferenceData"),
       do: on_conference_removal.()

    write_event(events, :put, uri, sent)
  end

  defp delete_event(events, uri) do
    key = event_key(uri, uri.path |> String.split("/") |> List.last())

    if Agent.get_and_update(events, &{Map.has_key?(&1, key), Map.delete(&1, key)}),
      do: {:ok, %Req.Response{status: 204, body: ""}},
      else: {:ok, %Req.Response{status: 404, body: ~s({"error":{"message":"Not Found"}})}}
  end

  defp meet_api(%URI{path: "/v2/spaces"}) do
    space = %{"name" => "spaces/space-1", "meetingUri" => @space_url}
    {:ok, %Req.Response{status: 200, body: Jason.encode!(space)}}
  end

  defp meet_api(_end_active_conference) do
    {:ok, %Req.Response{status: 400, body: ~s({"error":{"message":"No active conference."}})}}
  end

  # As Google does, an insert at an id an event already has is refused, and a
  # write at `conferenceDataVersion=1` sets the conference to what it carries,
  # which may be none.
  defp write_event(events, method, uri, sent) do
    id = if method == :post, do: sent["id"], else: uri.path |> String.split("/") |> List.last()
    key = event_key(uri, id)
    with_conference? = URI.decode_query(uri.query || "")["conferenceDataVersion"] == "1"

    exists? = Agent.get(events, &Map.has_key?(&1, key))

    cond do
      method == :post and exists? ->
        {:ok,
         %Req.Response{
           status: 409,
           body: ~s({"error":{"message":"The requested identifier already exists."}})
         }}

      method != :post and not exists? ->
        {:ok, %Req.Response{status: 404, body: ~s({"error":{"message":"Not Found"}})}}

      true ->
        store_event(events, key, sent, with_conference?)
    end
  end

  defp store_event(events, {_calendar, id} = key, sent, with_conference?) do
    event =
      Agent.get_and_update(events, fn stored ->
        previous = Map.get(stored, key, %{})

        {base, written} =
          if with_conference?,
            do: {Map.delete(previous, "conferenceData"), sent},
            else: {previous, Map.delete(sent, "conferenceData")}

        event =
          base
          |> Map.merge(written)
          |> Map.merge(%{"id" => id, "iCalUID" => "#{id}@google.com", "status" => "confirmed"})
          |> keep_conference(previous, with_conference?)
          |> with_offsets()
          |> pending_meet()

        {event, Map.put(stored, key, event)}
      end)

    {:ok, %Req.Response{status: 200, body: Jason.encode!(event)}}
  end

  defp keep_conference(event, %{"conferenceData" => conference}, false),
    do: Map.put(event, "conferenceData", conference)

  defp keep_conference(event, _previous, _with_conference?), do: event

  defp with_offsets(event) do
    event
    |> Map.update("start", nil, &offset_time/1)
    |> Map.update("end", nil, &offset_time/1)
  end

  defp offset_time(%{"dateTime" => local, "timeZone" => zone} = time) do
    case DateTime.from_iso8601(local) do
      {:ok, _with_offset, _seconds} ->
        time

      {:error, :missing_offset} ->
        zoned = local |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!(zone)
        Map.put(time, "dateTime", DateTime.to_iso8601(zoned))
    end
  end

  defp offset_time(time), do: time

  defp pending_meet(%{"conferenceData" => %{"createRequest" => request}} = event)
       when not is_map_key(request, "status") do
    put_in(event, ["conferenceData", "createRequest", "status"], %{"statusCode" => "pending"})
  end

  defp pending_meet(event), do: event

  defp made_meet(%{"conferenceData" => %{"createRequest" => _request} = conference} = event) do
    made =
      conference
      |> put_in(["createRequest", "status"], %{"statusCode" => "success"})
      |> Map.put("entryPoints", [%{"entryPointType" => "video", "uri" => @meet_url}])

    event
    |> Map.put("conferenceData", made)
    |> Map.put("hangoutLink", @meet_url)
  end

  defp made_meet(event), do: event

  @doc "The requests made since the last call, oldest first, as `{method, uri, body}`."
  @spec requests() :: [{atom(), URI.t(), map()}]
  def requests do
    receive do
      {:google, method, uri, body} -> [{method, uri, body} | requests()]
    after
      0 -> []
    end
  end
end
