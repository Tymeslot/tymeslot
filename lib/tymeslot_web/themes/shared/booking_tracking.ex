defmodule TymeslotWeb.Themes.Shared.BookingTracking do
  @moduledoc """
  First-touch attribution for the public scheduling flow: capturing UTM and
  referrer data at mount, and carrying it across the flow's routes.

  Split out of `TymeslotWeb.Themes.Shared.LiveHelpers`, which owns mounting
  and step entry. Attribution is its own concern: it is read once at mount,
  written onto the booking at submit time, and otherwise only threaded through
  navigation paths.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Analytics

  @doc """
  Captures UTM and arbitrary tracking params plus the referrer host from
  the request, and assigns the combined map under `:tracking`. The shape
  matches what `Tymeslot.Bookings.Create.execute/3` expects on the
  meeting params, so merging this assign into the meeting params at
  submit time persists the attribution on the booking.

  **First-touch attribution only.** This function is called once in `mount/3`.
  Internal LiveView navigations within the same session (e.g. schedule →
  booking → confirmation) do not invoke `mount/3` again, so the tracking
  assign is never refreshed mid-session. The UTM and referrer values
  recorded here reflect the URL the visitor first arrived on.
  """
  @spec assign_tracking(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_tracking(socket, params) do
    if Analytics.enabled?() do
      referrer = raw_referrer_from_socket(socket)

      tracking =
        params
        |> Analytics.extract_attribution(referrer)
        |> maybe_put_visitor_hash(socket)

      assign(socket, :tracking, tracking)
    else
      assign(socket, :tracking, %{})
    end
  end

  # `PageViewHook` (an on_mount hook, so it runs before this mount/3 helper)
  # computes the cookieless visitor hash and assigns it. Carry it into the
  # tracking map so it persists onto the booking and lets analytics join the
  # booking back to its page-view. Absent when the visit was not tracked
  # (e.g. dead render); then no hash is attached.
  defp maybe_put_visitor_hash(tracking, socket) do
    case socket.assigns[:visitor_hash] do
      hash when is_binary(hash) -> Map.put(tracking, :visitor_hash, hash)
      _other -> tracking
    end
  end

  @doc """
  Appends preserved tracking params to a path so UTM and custom URL
  params survive cross-route navigation in the scheduling flow.

  The `:referrer_host` key is local to the visitor's session (captured
  from the request header at mount) and is therefore omitted — it is
  not a query-string-shaped value.
  """
  @spec tracking_path(String.t(), map() | nil) :: String.t()
  def tracking_path(path, nil), do: path

  def tracking_path(path, tracking) do
    query =
      tracking
      |> Enum.flat_map(fn
        {:tracking_params, custom} when is_map(custom) -> Map.to_list(custom)
        {:referrer_host, _value} -> []
        {_key, nil} -> []
        {key, value} -> [{to_string(key), value}]
      end)
      |> URI.encode_query()

    cond do
      query == "" -> path
      String.contains?(path, "?") -> path <> "&" <> query
      true -> path <> "?" <> query
    end
  end

  defp raw_referrer_from_socket(socket) do
    socket.assigns[:scheduling_referrer]
  end
end
