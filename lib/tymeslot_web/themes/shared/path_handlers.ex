defmodule TymeslotWeb.Themes.Shared.PathHandlers do
  @moduledoc """
  Shared path building logic for theme scheduling LiveViews.
  """

  alias Tymeslot.MeetingTypes

  @doc """
  Builds a path with locale and theme query parameters.
  """
  @spec build_path_with_locale(Phoenix.LiveView.Socket.t(), String.t()) :: String.t()
  def build_path_with_locale(socket, locale) do
    base_path = get_base_path(socket)
    query_params = build_query_params(socket, locale)
    query_string = URI.encode_query(query_params)
    if query_string == "", do: base_path, else: "#{base_path}?#{query_string}"
  end

  defp get_base_path(socket) do
    username = socket.assigns[:username_context]

    if is_nil(username) do
      "/"
    else
      do_get_base_path(socket.assigns[:live_action], username, socket)
    end
  end

  defp do_get_base_path(:overview, username, _socket), do: "/#{username}"

  defp do_get_base_path(:schedule, username, socket) do
    slug = get_slug(socket)
    if slug, do: "/#{username}/#{slug}", else: "/#{username}"
  end

  defp do_get_base_path(:booking, username, socket) do
    slug = get_slug(socket)
    if slug, do: "/#{username}/#{slug}/book", else: "/#{username}"
  end

  defp do_get_base_path(:confirmation, username, _socket), do: "/#{username}/thank-you"

  defp do_get_base_path(:cancel, username, socket) do
    meeting_uid = socket.assigns[:meeting_uid]
    if meeting_uid, do: "/#{username}/meeting/#{meeting_uid}/cancel", else: "/#{username}"
  end

  defp do_get_base_path(:cancel_confirmed, username, socket) do
    meeting_uid = socket.assigns[:meeting_uid]

    if meeting_uid,
      do: "/#{username}/meeting/#{meeting_uid}/cancel-confirmed",
      else: "/#{username}"
  end

  defp do_get_base_path(:reschedule, username, socket) do
    meeting_uid = socket.assigns[:meeting_uid]
    if meeting_uid, do: "/#{username}/meeting/#{meeting_uid}/reschedule", else: "/#{username}"
  end

  defp do_get_base_path(_action, username, _socket), do: "/#{username}"

  defp build_query_params(socket, locale) do
    %{"locale" => locale}
    |> maybe_put_query_param("theme", socket.assigns[:theme_id])
    |> maybe_put_query_param("reschedule_meeting_uid", socket.assigns[:reschedule_meeting_uid])
  end

  defp get_slug(socket) do
    duration = socket.assigns[:duration] || socket.assigns[:selected_duration]
    MeetingTypes.normalize_duration_slug(duration)
  end

  defp maybe_put_query_param(params, _param_key, value) when value in [nil, ""], do: params
  defp maybe_put_query_param(params, key, value), do: Map.put(params, key, value)

  @doc """
  Returns the organizer's scheduling page path for restarting a booking,
  e.g. "/username".

  Invoked from the reschedule flow's "Choose New Time" CTA. When a
  `:meeting_uid` is present in the assigns it is carried forward as the
  `reschedule_meeting_uid` query param, so the restarted booking updates
  the existing meeting instead of silently creating a duplicate — the
  reschedule context is derived solely from that param
  (`LiveHelpers.handle_param_updates/2`).

  Falls back to "/" if the profile or username is unavailable.
  """
  @spec organizer_scheduling_path(map()) :: String.t()
  def organizer_scheduling_path(assigns) do
    case assigns[:organizer_profile] do
      %{username: username} when is_binary(username) and username != "" ->
        maybe_append_reschedule_uid("/#{username}", assigns[:meeting_uid])

      _other ->
        "/"
    end
  end

  defp maybe_append_reschedule_uid(base_path, uid) when is_binary(uid) and uid != "" do
    "#{base_path}?#{URI.encode_query(%{"reschedule_meeting_uid" => uid})}"
  end

  defp maybe_append_reschedule_uid(base_path, _uid), do: base_path
end
