defmodule Tymeslot.Analytics.PageViewHook do
  @moduledoc """
  LiveView `on_mount` hook that logs a `booking_page_view` event when
  a connected socket mounts on a public scheduling page.

  The hook only fires on `connected?(socket)` — the initial static
  HTML render is skipped, which automatically filters out the bulk
  of crawlers that never establish a WebSocket. Remaining bot user
  agents are filtered by `Tymeslot.Analytics.log_page_view/1`, which
  also applies per-visitor rate limiting before persisting.

  The actual write happens inside a supervised Task to avoid adding
  latency to the LiveView mount path. Any failure inside the Task
  is swallowed — analytics must never break the booking flow.
  """
  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2]

  alias Tymeslot.Analytics
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, _session, socket) do
    if connected?(socket) do
      log_async(params, socket)
    end

    {:cont, socket}
  end

  defp log_async(params, socket) do
    user_agent = extract_user_agent(socket)
    ip = extract_peer_ip(socket)
    referrer = extract_header(socket, "referer")
    {user_id, meeting_type_id, path} = resolve_target(params)

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      Analytics.log_page_view(%{
        path: path,
        user_id: user_id,
        meeting_type_id: meeting_type_id,
        ip: ip,
        user_agent: user_agent,
        session_id: socket.id,
        params: params,
        referrer: referrer
      })
    end)
  end

  defp extract_user_agent(socket) do
    case get_connect_info(socket, :user_agent) do
      ua when is_binary(ua) and ua != "" -> ua
      _other -> extract_header(socket, "user-agent")
    end
  end

  defp extract_peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} when is_tuple(address) ->
        address |> :inet.ntoa() |> to_string()

      _other ->
        nil
    end
  end

  defp extract_header(socket, name) do
    case get_connect_info(socket, :x_headers) do
      headers when is_list(headers) ->
        Enum.find_value(headers, fn {k, v} ->
          if String.downcase(to_string(k)) == name, do: v
        end)

      _other ->
        nil
    end
  end

  defp resolve_target(params) do
    username = params["username"]
    slug = params["slug"]

    case {Profiles.get_profile_by_username(username), slug} do
      {%{user_id: user_id}, slug} when is_binary(slug) ->
        meeting_type_id =
          case MeetingTypes.find_by_slug(user_id, slug) do
            %{id: id} -> id
            _other -> nil
          end

        {user_id, meeting_type_id, build_path(username, slug)}

      {%{user_id: user_id}, _slug} ->
        {user_id, nil, build_path(username, nil)}

      {_profile, _slug} ->
        {nil, nil, build_path(username, slug)}
    end
  end

  defp build_path(nil, _slug), do: "/"
  defp build_path(username, nil), do: "/#{username}"
  defp build_path(username, slug), do: "/#{username}/#{slug}"
end
