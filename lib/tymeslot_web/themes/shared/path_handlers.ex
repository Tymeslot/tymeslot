defmodule TymeslotWeb.Themes.Shared.PathHandlers do
  @moduledoc """
  Shared path building logic for theme scheduling LiveViews.
  """

  use TymeslotWeb, :verified_routes

  alias Tymeslot.BookingPages
  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Reveal

  # The route's own segments, which arrive in `params` beside the query.
  @path_params ["username", "page", "slug"]

  # What makes a page a reschedule rather than a booking.
  @reschedule_params ["reschedule_meeting_uid", "reschedule_seat_token"]

  # What the path or the booking's facts now say, and what a classic
  # confirmation link names (who booked, and which meeting), never carried in
  # a facts address's query.
  @fact_params ~w(date time duration name email meeting_uid)

  # What a page carries of the visitor's choices: the deep-link parameters
  # `put_choices/2` writes, the chosen length, and a facts address's mark of
  # a visit that came through the overview (`facts_address/1`).
  @choice_params ["duration", "date", "time", "minutes", "visitor_timezone", "step", "via"]

  @doc """
  Builds a path with locale and theme query parameters.
  """
  @spec build_path_with_locale(Phoenix.LiveView.Socket.t(), String.t()) :: String.t()
  def build_path_with_locale(socket, locale) do
    socket.assigns
    |> current_base_path()
    |> with_query(build_query_params(socket, locale))
  end

  @doc """
  The path of the step the page's route names (`/username`,
  `/username/slug`, `/username/slug/book`, ...), with no query. Under a
  booking page, `username` is the page's address, `<username>/<page>`
  (`TymeslotWeb.Live.Scheduling.PageAddress`), and every path here follows
  it. The page's
  links back to itself start from it: the locale switch and the demo's theme
  switcher.
  """
  @spec current_base_path(map()) :: String.t()
  def current_base_path(assigns) do
    case assigns[:username_context] do
      nil -> "/"
      username -> base_path(route(assigns), username, assigns)
    end
  end

  @doc """
  The address a booking's known facts give, for a journey whose address
  follows them (`url: :facts`): `/:username` before a meeting type is known,
  `/:username/:slug` with one (the type's own slug, `MeetingTypes.effective_slug/1`),
  `/:username/:slug/book` once the day and the time are, and
  `/:username/thank-you` on the confirmation. `nil` without an organiser.
  """
  @spec facts_path(map()) :: String.t() | nil
  def facts_path(%{username_context: username} = assigns) when is_binary(username) do
    slug = facts_slug(assigns)

    cond do
      assigns[:current_state] == :confirmation -> "/#{username}/thank-you"
      is_nil(slug) -> "/#{username}"
      slot_known?(assigns) -> "/#{username}/#{slug}/book"
      true -> "/#{username}/#{slug}"
    end
  end

  def facts_path(_assigns), do: nil

  @doc """
  The whole address a journey whose address follows its facts moves to
  (`ChoicesInUrl`): `facts_path/1`, with the page's own query
  (`facts_query/1`) and the choices the path cannot say, as
  `choices_query/1` carries them on any other journey: the day and the time
  (the path says only that both are known), a timezone the visitor chose,
  the length and the moment on screen. The meeting type is the path's, so
  it never goes as `duration`; an outcome carries no choices, and the
  confirmation no invitation token. A visit that
  came through the overview, whose route the path has left, goes as
  `via=overview`, so a reconnect keeps the way back to the meeting types
  (`LiveHelpers.Mount` honours it only for a type the overview lists).
  `nil` without an organiser.
  """
  @spec facts_address(map()) :: String.t() | nil
  def facts_address(assigns) do
    if path = facts_path(assigns) do
      query =
        assigns
        |> facts_query_params()
        |> Map.drop(@choice_params)
        |> maybe_put_query_param("minutes", chosen_length(assigns))
        |> put_choices(assigns)
        |> Map.delete("duration")
        |> maybe_put_query_param("via", overview_mark(path, assigns))
        |> drop_spent_invite(assigns)

      with_query(path, query)
    end
  end

  defp overview_mark(path, assigns) do
    if assigns[:entered_via_overview] == true and path != "/#{assigns[:username_context]}" and
         assigns[:current_state] not in [:confirmation, :awaiting_payment],
       do: "overview"
  end

  @doc """
  The start of a journey whose address follows its facts, `/:username`, with
  the page's own query (`facts_query/1`); `/` without an organiser.
  """
  @spec facts_start(map()) :: String.t()
  def facts_start(%{username_context: username} = assigns) when is_binary(username) do
    case facts_query(assigns) do
      nil -> "/#{username}"
      query -> "/#{username}?#{query}"
    end
  end

  def facts_start(_assigns), do: "/"

  defp facts_slug(assigns) do
    slug =
      case assigns[:meeting_type] do
        %{} = meeting_type ->
          MeetingTypes.effective_slug(meeting_type)

        _none ->
          MeetingTypes.normalize_duration_slug(assigns[:duration] || assigns[:selected_duration])
      end

    if is_binary(slug) and slug != "", do: URI.encode(slug, &URI.char_unreserved?/1)
  end

  defp slot_known?(assigns),
    do: is_binary(assigns[:selected_date]) and is_binary(assigns[:selected_time])

  @doc """
  The query string a journey whose address follows its facts keeps: the
  page's own parameters (`:page_query_params`) less the day, the time and
  the duration, which the facts now say, less a confirmation link's name,
  email and meeting, and less the reschedule once it is abandoned (no
  `reschedule_meeting_uid` and no `reschedule_seat_token` left on the
  page). `nil` when nothing is left.
  """
  @spec facts_query(map()) :: String.t() | nil
  def facts_query(assigns) do
    case facts_query_params(assigns) do
      empty when map_size(empty) == 0 -> nil
      query -> URI.encode_query(query)
    end
  end

  defp facts_query_params(assigns) do
    dropped =
      if is_nil(assigns[:reschedule_meeting_uid]) and is_nil(assigns[:reschedule_seat_token]),
        do: @fact_params ++ @reschedule_params,
        else: @fact_params

    Map.drop(assigns[:page_query_params] || %{}, dropped)
  end

  @doc "`path` with `query` appended, or `path` alone when `query` is empty."
  @spec with_query(String.t(), map()) :: String.t()
  def with_query(path, query) when map_size(query) == 0, do: path
  def with_query(path, query), do: path <> "?" <> URI.encode_query(query)

  @doc """
  The `theme` parameter a demo page's redirects carry: the theme the page
  shows, when it is not the organiser's own, so a visitor who picked another
  one in the demo's switcher (`Components.DemoThemeSwitcher`) keeps it on the
  page the flow sends them to. Empty on every page that is not a demo, where
  only previews and embeds carry `?theme=` (issue #84).
  """
  @spec demo_theme_param(map()) :: %{optional(String.t()) => String.t()}
  def demo_theme_param(%{demo_theme_switcher: true, theme_id: theme_id} = assigns)
      when is_binary(theme_id) do
    case assigns[:organizer_profile] do
      %{booking_theme: ^theme_id} -> %{}
      _another_theme -> %{"theme" => theme_id}
    end
  end

  def demo_theme_param(_assigns), do: %{}

  @doc """
  The `invite` parameter a redirect from the booking page carries, so a page
  let in on an invitation (`LiveHelpers.InvitationGate`) is let in again on
  the page the redirect lands: the token of the invitation the page holds,
  else the one its URL arrived with. Empty on a page with neither. The
  page's own address (`choices_query/1`) keeps it until the confirmation; a
  link that rebuilds the query needs it, as the locale switch and the
  restart (`restart_path/2`) do.
  """
  @spec invite_param(map()) :: %{optional(String.t()) => String.t()}
  def invite_param(%{invitation: %{token: token}}) when is_binary(token) and token != "",
    do: %{"invite" => token}

  def invite_param(assigns) do
    case assigns[:page_query_params] do
      %{"invite" => token} when is_binary(token) and token != "" -> %{"invite" => token}
      _none -> %{}
    end
  end

  defp base_path(:overview, username, _assigns), do: "/#{username}"

  defp base_path(:schedule, username, assigns) do
    slug = get_slug(assigns)
    if slug, do: "/#{username}/#{slug}", else: "/#{username}"
  end

  defp base_path(:booking, username, assigns) do
    slug = get_slug(assigns)
    if slug, do: "/#{username}/#{slug}/book", else: "/#{username}"
  end

  defp base_path(:confirmation, username, _assigns), do: "/#{username}/thank-you"

  defp base_path(:cancel, username, assigns) do
    meeting_uid = assigns[:meeting_uid]
    if meeting_uid, do: "/#{username}/meeting/#{meeting_uid}/cancel", else: "/#{username}"
  end

  defp base_path(:cancel_confirmed, username, assigns) do
    meeting_uid = assigns[:meeting_uid]

    if meeting_uid,
      do: "/#{username}/meeting/#{meeting_uid}/cancel-confirmed",
      else: "/#{username}"
  end

  defp base_path(:reschedule, username, assigns) do
    meeting_uid = assigns[:meeting_uid]
    if meeting_uid, do: "/#{username}/meeting/#{meeting_uid}/reschedule", else: "/#{username}"
  end

  defp base_path(_action, username, _assigns), do: "/#{username}"

  defp build_query_params(socket, locale) do
    %{"locale" => locale}
    |> put_embed_params(socket)
    |> put_preview_params(socket)
    |> Map.merge(demo_theme_param(socket.assigns))
    |> maybe_put_query_param("reschedule_meeting_uid", socket.assigns[:reschedule_meeting_uid])
    |> maybe_put_query_param("minutes", chosen_length(socket.assigns))
    |> maybe_put_query_param("reschedule_seat_token", socket.assigns[:reschedule_seat_token])
    |> Map.merge(invite_param(socket.assigns))
    |> put_choices(socket.assigns)
  end

  # What a fresh booking forgets of them: everything built on the meeting
  # type, which a restart keeps (`Journey.Runtime.restart/1`).
  @slot_params ["date", "time", "minutes", "step"]

  @doc """
  The query string that carries the visitor's choices on the page's own URL
  (`ChoicesInUrl`): the page's own query (an embed's parameters, a preview,
  a reschedule, the locale it arrived with), with the choices it named on
  arrival replaced by the ones made since. The confirmation drops the
  invitation token the booking spent.
  """
  @spec choices_query(Phoenix.LiveView.Socket.t()) :: %{String.t() => String.t()}
  def choices_query(socket) do
    (socket.assigns[:page_query_params] || %{})
    |> Map.drop(@choice_params)
    |> maybe_put_query_param("minutes", chosen_length(socket.assigns))
    |> put_choices(socket.assigns)
    |> drop_spent_invite(socket.assigns)
  end

  # The confirmation's address does not keep the invitation's token: the
  # booking has spent it, and an address bar is copied, shared and kept in
  # history. The steps before it keep it, so the page lets the guest in
  # again on a reconnect or a locale switch, and a restart names it again
  # (`restart_path/2`).
  defp drop_spent_invite(query, %{current_state: :confirmation}), do: Map.delete(query, "invite")
  defp drop_spent_invite(query, _assigns), do: query

  defp chosen_length(%{current_state: state}) when state in [:confirmation, :awaiting_payment],
    do: nil

  defp chosen_length(assigns), do: assigns[:chosen_length_minutes]

  # The visitor's choices, as the deep-link parameters a mount reads back, so
  # a page mounted from them lands where the visitor was: the locale switch
  # (a full redirect) and the patch that keeps the address bar in step with
  # every choice (`ChoicesInUrl`), whose URL a reconnect remounts from. The
  # route stays the one the visit started on, which is what
  # `entered_via_overview` is read from: a type chosen on the overview goes
  # as `duration` on the overview route (a type the overview does not list
  # is never taken from it), and a meeting type's own link names its type in
  # the path. A time no longer free is dropped on arrival, as a deep link's
  # is. The day and time are wall clock in the visitor's timezone, so a zone
  # the visitor chose over their browser's goes too (`visitor_timezone`,
  # which the mount prefers to the browser's); their browser's own zone is
  # left out, since every browser reports its own again on connect.
  # A paged journey shows one moment at a time and does not move on by
  # itself, so the moment on screen goes as `step` (`Navigators.Paged`
  # resumes on it). The answers and the details are not carried: the
  # details form is recovered by LiveView's form recovery. Nor is anything
  # on an outcome, whose choices are a booking already made (carried, a
  # reload of the confirmation would land on the details for the slot just
  # booked).
  defp put_choices(params, assigns) do
    if assigns[:current_state] in [:confirmation, :awaiting_payment] do
      params
    else
      params
      |> maybe_put_query_param("duration", overview_choice(assigns))
      |> maybe_put_query_param("date", assigns[:selected_date])
      |> maybe_put_query_param("time", assigns[:selected_date] && assigns[:selected_time])
      |> maybe_put_query_param("visitor_timezone", chosen_timezone(assigns))
      |> maybe_put_query_param("step", paged_moment(assigns))
    end
  end

  # Not the zone the browser reported, which every browser reports again on
  # connect, so that a link copied from the address bar shows its next reader
  # times in their own zone. Before the browser has reported one, the zone
  # goes as it is.
  defp chosen_timezone(%{user_timezone: zone, browser_timezone: zone}), do: nil
  defp chosen_timezone(assigns), do: assigns[:user_timezone]

  defp paged_moment(%{journey: journey, current_state: state}) when is_atom(state) do
    if not Reveal.journey?(journey) and Journey.moment(journey, state),
      do: Atom.to_string(state)
  end

  defp paged_moment(_assigns), do: nil

  defp overview_choice(assigns) do
    if route(assigns) == :overview,
      do: MeetingTypes.normalize_duration_slug(assigns[:selected_duration])
  end

  # The route the switch rebuilds: on a journey whose address follows its
  # facts, the one the visit started on (the address has moved since, and
  # the choices travel as parameters, `put_choices/2`); otherwise the
  # current one. The journey is matched as a map, so this module takes no
  # compile-time dependency on it.
  defp route(%{journey: %{url: :facts}, entry_action: action})
       when is_atom(action) and action != nil,
       do: action

  defp route(assigns), do: assigns[:live_action]

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
  # A demo page is the one other carrier, through `demo_theme_param/1`, and
  # only for a theme the visitor chose.
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

  defp get_slug(assigns) do
    duration = assigns[:duration] || assigns[:selected_duration]
    MeetingTypes.normalize_duration_slug(duration)
  end

  defp maybe_put_query_param(params, _param_key, value) when value in [nil, ""], do: params
  # As the URL will read it back: a string (the chosen length is an integer).
  defp maybe_put_query_param(params, key, value), do: Map.put(params, key, to_string(value))

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
  the reschedule it was for is dropped, with the slot and everything else
  the URL carried of the last booking but its meeting type.

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

    # The confirmation's address no longer carries the invitation, so the
    # restart names the one the page holds (`invite_param/1`).
    query =
      (socket.assigns[:page_query_params] || %{})
      |> Map.drop(@reschedule_params ++ @slot_params)
      |> Map.merge(invite_param(socket.assigns))

    if query == %{}, do: base, else: "#{base}?#{URI.encode_query(query)}"
  end

  defp restart_base(:schedule, username, socket),
    do: base_path(:schedule, username, socket.assigns)

  defp restart_base(_overview, username, _socket), do: "/#{username}"

  @doc "Whether the page's URL carries a reschedule."
  @spec reschedule_in_url?(Phoenix.LiveView.Socket.t()) :: boolean()
  def reschedule_in_url?(socket) do
    Enum.any?(@reschedule_params, &Map.has_key?(socket.assigns[:page_query_params] || %{}, &1))
  end

  @doc """
  Returns the organizer's scheduling page path for restarting a booking,
  e.g. "/username", or "/username/page" for an organiser resolved through
  one of their booking pages.

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
    case BookingPages.public_address(assigns[:organizer_profile]) do
      address when is_binary(address) and address != "" ->
        maybe_append_reschedule_uid("/#{address}", assigns[:meeting_uid])

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

  # The meeting's file is the host's, under the username, whichever of their
  # pages (`<username>/<page>`) it was booked on.
  def calendar_ics_path(%{username_context: address, meeting_uid: uid})
      when is_binary(address) and address != "" and is_binary(uid) and uid != "" do
    [username | _page] = String.split(address, "/", parts: 2)
    ~p"/#{username}/meeting/#{uid}/calendar.ics"
  end

  def calendar_ics_path(_assigns), do: nil
end
