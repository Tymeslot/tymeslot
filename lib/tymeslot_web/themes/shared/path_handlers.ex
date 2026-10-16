defmodule TymeslotWeb.Themes.Shared.PathHandlers do
  @moduledoc """
  Shared path building logic for theme scheduling LiveViews.
  """

  use TymeslotWeb, :verified_routes

  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Reveal

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
    |> put_embed_params(socket)
    |> put_preview_params(socket)
    |> maybe_put_query_param("reschedule_meeting_uid", socket.assigns[:reschedule_meeting_uid])
    |> maybe_put_query_param("reschedule_seat_token", socket.assigns[:reschedule_seat_token])
    |> put_choices(socket.assigns)
  end

  # A page that opens its moments by itself shows the switcher on every
  # moment, so a switch can come after the visitor has chosen. The redirect
  # carries the choices as the deep-link parameters, and the page that comes
  # back lands where the visitor was. The route stays the one the visit
  # started on, which is what `entered_via_overview` is read from: a type
  # chosen on the overview goes as `duration` on the overview route (a type
  # the overview does not list is never taken from it), and a meeting
  # type's own link names its type in the path. A time no longer free is
  # dropped on arrival, as a deep link's is. The day and time are wall clock
  # in the visitor's timezone, so that goes too (`visitor_timezone`, which the
  # mount prefers to the browser's). The answers and the details are not
  # carried. A paged journey's switcher shows on its first moment only,
  # before any choice, so it carries nothing; nor does an outcome, whose
  # choices are a booking already made (a switch on the confirmation would
  # otherwise land on the details for the slot just booked).
  defp put_choices(params, assigns) do
    if Reveal.journey?(assigns[:journey]) and
         assigns[:current_state] not in [:confirmation, :awaiting_payment] do
      params
      |> maybe_put_query_param("duration", overview_choice(assigns))
      |> maybe_put_query_param("date", assigns[:selected_date])
      |> maybe_put_query_param("time", assigns[:selected_date] && assigns[:selected_time])
      |> maybe_put_query_param("visitor_timezone", assigns[:user_timezone])
    else
      params
    end
  end

  defp overview_choice(%{live_action: :overview} = assigns),
    do: MeetingTypes.normalize_duration_slug(assigns[:selected_duration])

  defp overview_choice(_assigns), do: nil

  # `theme` rides along here and nowhere else, which is the fix for #84. It used
  # to be emitted on every locale switch from `:theme_id`, an assign the
  # dispatcher always sets, so it was never a signal that anyone was
  # previewing. Every visitor who changed the language landed on a `theme=`
  # URL, which was then read as a preview and failed their booking closed,
  # silently.
  #
  # The preview parameters have to be rebuilt as a set, not one by one. A locale
  # switch is a full external redirect, so the LiveView that comes back has no
  # assigns and knows only what the URL carries. Dropping `preview=` here would
  # land the owner on a page that still looks like their preview but persists a
  # real meeting; dropping `preview_token` would fail their booking closed. Both
  # were live defects the moment `?theme=` stopped standing in for the claim.
  defp put_preview_params(params, socket) do
    if preview_session?(socket) do
      params
      |> Map.put("preview", "true")
      |> maybe_put_query_param("theme", socket.assigns[:theme_id])
      |> maybe_put_query_param("preview_token", socket.assigns[:preview_token])
    else
      params
    end
  end

  # An embedded page has to be rebuilt as an embed for the same reason: the
  # redirect lands a fresh LiveView that knows only what the URL carries.
  # Without `embed=1` the new request has no embed token, so the page is no
  # longer treated as embedded (a paid booking tries to open Stripe Checkout
  # inside the iframe), and the embed's layout, accent colour and theme revert
  # to the organiser's defaults.
  #
  # Every value comes from what the page already validated, never from the raw
  # params: `:embedded` and `:embed_parent_origin` from the verified embed
  # token, the rest from the theme context. Carrying `theme` is safe here
  # because a bare `theme=` is no longer a preview claim
  # (`PreviewMode.claimed?/1`); the embed selected it and must keep it.
  defp put_embed_params(params, socket) do
    if socket.assigns[:embedded] do
      params
      |> Map.put("embed", "1")
      |> maybe_put_query_param("parent-origin", socket.assigns[:embed_parent_origin])
      |> maybe_put_query_param("theme", socket.assigns[:theme_id])
      |> maybe_put_query_param("layout", column_layout(socket.assigns[:embed_layout]))
      |> maybe_put_query_param("primary-color", primary_colour(socket.assigns[:theme_overrides]))
    else
      params
    end
  end

  defp column_layout(:column), do: "column"
  defp column_layout(_default), do: nil

  defp primary_colour(%{primary_color: colour}), do: colour
  defp primary_colour(_no_override), do: nil

  # Either half is enough: `:theme_preview` is the URL's claim, `:owner_preview`
  # the verified token, and internal navigation can leave only the latter set.
  defp preview_session?(socket) do
    socket.assigns[:theme_preview] || socket.assigns[:owner_preview] || false
  end

  defp get_slug(socket) do
    duration = socket.assigns[:duration] || socket.assigns[:selected_duration]
    MeetingTypes.normalize_duration_slug(duration)
  end

  defp maybe_put_query_param(params, _param_key, value) when value in [nil, ""], do: params
  defp maybe_put_query_param(params, key, value), do: Map.put(params, key, value)

  # The route's own segments, which arrive in `params` beside the query.
  @path_params ["username", "slug"]

  # What makes a page a reschedule rather than a booking.
  @reschedule_params ["reschedule_meeting_uid", "reschedule_seat_token"]

  @doc """
  The query string parameters of a booking page's `params`: everything but
  the route's own segments, and only the string-valued ones a URL can carry
  back.
  """
  @spec query_params(map()) :: %{String.t() => String.t()}
  def query_params(params) do
    for {key, value} <- Map.drop(params, @path_params), is_binary(value), into: %{} do
      {key, value}
    end
  end

  @doc """
  The host's booking page from the start, as a fresh booking: the page's
  own query (an embed's parameters, a preview, the timezone) is kept, and
  only the reschedule it was for is dropped.

  `route` is where the booking starts again: `:overview`, the host's page
  with every meeting type, or `:schedule`, the chosen meeting type's own
  link, so a booker who came by a direct or private link is not shown the
  host's other types.
  """
  @spec restart_path(Phoenix.LiveView.Socket.t(), :overview | :schedule) :: String.t()
  def restart_path(socket, route \\ :overview) do
    base =
      case socket.assigns[:username_context] do
        username when is_binary(username) -> restart_base(route, username, socket)
        _none -> "/"
      end

    query = Map.drop(socket.assigns[:page_query_params] || %{}, @reschedule_params)
    if query == %{}, do: base, else: "#{base}?#{URI.encode_query(query)}"
  end

  defp restart_base(:schedule, username, socket),
    do: do_get_base_path(:schedule, username, socket)

  defp restart_base(_overview, username, _socket), do: "/#{username}"

  @doc "Whether the page's URL carries a reschedule."
  @spec reschedule_in_url?(Phoenix.LiveView.Socket.t()) :: boolean()
  def reschedule_in_url?(socket) do
    Enum.any?(@reschedule_params, &Map.has_key?(socket.assigns[:page_query_params] || %{}, &1))
  end

  @doc """
  Returns the organizer's scheduling page path for restarting a booking,
  e.g. "/username".

  Invoked from the reschedule flow's "Choose New Time" CTA. When a
  `:meeting_uid` is present in the assigns it is carried forward as the
  `reschedule_meeting_uid` query param, so the restarted booking updates
  the existing meeting instead of silently creating a duplicate — the
  reschedule context is derived solely from that param
  (`LiveHelpers.Mount.handle_scheduling_params/2`).

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

  @doc """
  The confirmation step's "Add to calendar" link: the booked meeting as a
  downloadable `.ics` file, served by `MeetingCalendarController`.

  A seat on a group meeting downloads the seat's own file under its
  management token instead (`:seat_calendar_url`, set when the seat was
  booked): the meeting uid of a group meeting names the shared slot, which is
  never the booker's to hold, export or manage.

  `nil` until the meeting has a uid and the page knows its organiser, which
  is how the templates decide whether to show the link at all.
  """
  @spec calendar_ics_path(map()) :: String.t() | nil
  def calendar_ics_path(%{seat_calendar_url: url}) when is_binary(url) and url != "", do: url

  def calendar_ics_path(%{username_context: username, meeting_uid: uid})
      when is_binary(username) and username != "" and is_binary(uid) and uid != "",
      do: ~p"/#{username}/meeting/#{uid}/calendar.ics"

  def calendar_ics_path(_assigns), do: nil
end
