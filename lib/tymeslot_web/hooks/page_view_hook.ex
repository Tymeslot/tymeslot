defmodule TymeslotWeb.Hooks.PageViewHook do
  @moduledoc """
  LiveView `on_mount` hook that logs a `booking_page_view` event when
  a connected socket mounts on a public scheduling page.

  No work is scheduled unless booking analytics is enabled
  (`Tymeslot.Analytics.enabled?/0`); when disabled the hook is a no-op
  beyond assigning the session referrer.

  The hook only fires on `connected?(socket)` — the initial static
  HTML render is skipped, which automatically filters out the bulk
  of crawlers that never establish a WebSocket. Remaining bot user
  agents are filtered by `Tymeslot.Analytics.log_page_view/1`, which
  also applies per-visitor rate limiting before persisting.

  The actual write happens inside a supervised Task to avoid adding
  latency to the LiveView mount path. Any failure inside the Task
  is swallowed — analytics must never break the booking flow.

  Only cheap, in-memory data (user agent, IP, socket ID, params,
  session referrer) is captured before spawning the Task. The
  database lookups for user and meeting-type context run inside the
  Task, off the mount path.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2]

  alias Tymeslot.Analytics
  alias Tymeslot.Analytics.Fingerprint
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  @scheduling_referrer_session_key "scheduling_referrer"

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, session, socket) do
    referrer = session[@scheduling_referrer_session_key]
    socket = assign(socket, :scheduling_referrer, referrer)

    if connected?(socket) and Analytics.enabled?() do
      {:cont, track_connected(socket, params, referrer)}
    else
      {:cont, socket}
    end
  end

  # Compute the visitor hash exactly once, here, from this hook's (Cloudflare-
  # aware) IP/UA extraction. The hash is assigned to the socket so a later
  # booking can persist the *same* value — `assign_tracking/2` folds it into the
  # `:tracking` map. The async page-view write recomputes the hash from the
  # identical (ip, user_agent, session_id) inputs, so the event and the booking
  # always share one join key. Anything else risks two extractors disagreeing
  # and the conversion join silently matching nothing.
  defp track_connected(socket, params, referrer) do
    user_agent = extract_user_agent(socket)
    ip = extract_peer_ip(socket)
    session_id = socket.id

    socket = assign(socket, :visitor_hash, Fingerprint.hash(ip, user_agent, session_id))

    log_async(params, referrer, ip, user_agent, session_id)

    socket
  end

  defp log_async(params, referrer, ip, user_agent, session_id) do
    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      {user_id, meeting_type_id, path} = resolve_target(params)

      Analytics.log_page_view(%{
        path: path,
        user_id: user_id,
        meeting_type_id: meeting_type_id,
        ip: ip,
        user_agent: user_agent,
        session_id: session_id,
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
    forwarded =
      case get_connect_info(socket, :x_headers) do
        headers when is_list(headers) -> find_forwarded_ip(headers)
        _other -> nil
      end

    forwarded ||
      case get_connect_info(socket, :peer_data) do
        %{address: address} when is_tuple(address) -> address |> :inet.ntoa() |> to_string()
        _other -> nil
      end
  end

  # Check proxy headers in priority order: x-forwarded-for (first IP),
  # x-real-ip, then cf-connecting-ip (Cloudflare).
  defp find_forwarded_ip(headers) do
    Enum.find_value(
      ["x-forwarded-for", "x-real-ip", "cf-connecting-ip"],
      fn name ->
        Enum.find_value(headers, fn {k, v} ->
          if String.downcase(to_string(k)) == name do
            v |> String.split(",") |> List.first() |> String.trim()
          end
        end)
      end
    )
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

  defp resolve_target(%{"username" => username} = params) when is_binary(username) do
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

  defp resolve_target(_params), do: {nil, nil, "/"}

  defp build_path(username, nil), do: "/#{username}"
  defp build_path(username, slug), do: "/#{username}/#{slug}"
end
