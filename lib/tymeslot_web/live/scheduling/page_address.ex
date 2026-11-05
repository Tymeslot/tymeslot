defmodule TymeslotWeb.Live.Scheduling.PageAddress do
  @moduledoc """
  Settles which start page a booking URL is for, before any theme sees it.

  It runs once per mount, as the scheduling routes' `on_mount` hook (ahead of
  `TymeslotWeb.Hooks.ThemeHook`), and leaves what it found in the
  `:page_address` assign: the settled `params`, and the organiser, with
  their user, as the page presents them. The hook picks the theme from that
  organiser, and the dispatcher mounts the settled params and builds the
  organiser context from them, so neither looks the profile or the page up
  again.

  A host's booking pages live under the username: `/<username>/<page>`, with
  the flow's steps beneath (`/<username>/<page>/<type>`, `.../book`,
  `/<username>/<page>/thank-you`). The router cannot tell `/<username>/<x>`
  apart, since `x` is a page's slug or a meeting type's, so it routes it as
  a meeting type (`:schedule`) and this module reads it once, for the
  dispatcher, on mount (`settle/2`) and again on every `handle_params`
  (`follow/3`, since a patch resets the live action to the route's).
  `/<username>/<x>/book` is read the same way: the booking step of the type
  `x`, or, where `x` is a page, that page's type whose slug is "book" (a
  name-derived slug, which no reserved list can keep from "book").

  Settled, a page's URL has a `"page"` param and the live action of the step
  beneath it (`:overview` for its start page); everything else is unchanged.
  The flow then works on the address `<username>/<page>` (`address/1`) and
  never needs to know pages exist.

  Settling also answers the URLs that are not where they say:

    * a username or page typed with capitals redirects to the lowercase path;
    * a page's former slug redirects to the same path under its current one,
      or under the username once the page is gone (`BookingPages.locate/2`);
    * a draft page (`BookingPages.published?/1`) is not found, except to its
      owner's preview (a verified `preview_token`): under it, nothing is
      there; at `/<username>/<x>`, `x` is taken for a meeting type's slug,
      as for any slug that names no page.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [redirect: 2]

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Live.Scheduling.PreviewToken
  alias TymeslotWeb.Themes.Shared.PathHandlers

  @scheduling_actions [:overview, :schedule, :booking, :confirmation]

  @doc """
  Settles the URL on mount (`settle/2`): assigns the settled live action and
  `:page_address`, `%{params: settled_params, organiser: profile_or_nil}`,
  halts with a redirect for a URL that has moved, and raises
  `TymeslotWeb.NotFoundError` for a page address that leads nowhere.
  """
  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, _session, socket) do
    case settle(params, socket.assigns[:live_action]) do
      {:ok, settled, action, organiser} ->
        {:cont,
         assign(socket,
           live_action: action,
           page_address: %{params: settled, organiser: organiser}
         )}

      {:redirect, path} ->
        {:halt, redirect(socket, to: path)}

      :not_found ->
        raise TymeslotWeb.NotFoundError, "No booking page found for #{inspect(params["page"])}"
    end
  end

  @doc """
  Settles `params` and the route's `action`: `{:ok, params, action,
  organiser}` to go ahead with, `{:redirect, path}` for a URL that has
  moved, or `:not_found` for a page address that leads nowhere.

  `organiser` is the username's profile, with its user, as the settled page
  presents it
  (`BookingPages.apply_to_profile/2`): wearing a page only where the URL is
  that page's and it is published or previewed by its owner, so a draft
  never lends its look to a meeting type's URL. It is nil for a username
  that names no profile, or anything but a scheduling route, which go ahead
  as they are; the flow answers them as before.
  """
  @spec settle(map(), atom()) ::
          {:ok, map(), atom(), ProfileSchema.t() | nil} | {:redirect, String.t()} | :not_found
  def settle(%{"username" => username} = params, action)
      when is_binary(username) and action in @scheduling_actions do
    username
    |> String.downcase()
    |> Profiles.get_organizer_by_username()
    |> settle_for(params, action, candidate(params, action))
  end

  def settle(params, action), do: {:ok, params, action, nil}

  @doc """
  `settle/2`'s reading of a page's own URL again, for `handle_params`, from
  the organiser the mount resolved: `/<username>/<x>` where `x` is that
  page's slug is its start page, and `/<username>/<x>/book` its type slugged
  "book". Any other URL is left as it is.

  The route is read from `url`, not from `action`: after a patch the action
  is the route's, but on mount it is the one `settle/2` already chose, while
  `params` are the route's either way.
  """
  @spec follow(map(), atom(), map() | nil, String.t()) :: {map(), atom()}
  def follow(%{"slug" => slug} = params, action, %{booking_page: %{slug: slug}}, url)
      when action in [:schedule, :booking] and not is_map_key(params, "page") do
    case URI.parse(url).path |> to_string() |> String.split("/", trim: true) do
      [_username, _slug] -> at_page(params, :schedule, slug)
      [_username, _slug, "book"] -> at_page(params, :booking, slug)
      _other -> {params, action}
    end
  end

  def follow(params, action, _organizer_profile, _url), do: {params, action}

  @doc """
  The address the flow works under for settled `params`: the username, or
  `<username>/<page>`. nil without a username.
  """
  @spec address(map()) :: String.t() | nil
  def address(%{"username" => username, "page" => page})
      when is_binary(username) and is_binary(page),
      do: username <> "/" <> page

  def address(%{"username" => username}) when is_binary(username), do: username
  def address(_params), do: nil

  # The segment that may be a page: the page route's own, or the `x` of
  # `/<username>/<x>` and `/<username>/<x>/book`.
  defp candidate(%{"page" => page}, _action) when is_binary(page), do: page

  defp candidate(%{"slug" => slug}, action)
       when is_binary(slug) and action in [:schedule, :booking],
       do: slug

  defp candidate(_params, _action), do: nil

  # No profile by that username: a page route leads nowhere; anything else
  # goes on to the flow, which knows demo organisers and answers the rest.
  defp settle_for(nil, params, action, _candidate) do
    if Map.has_key?(params, "page"), do: :not_found, else: {:ok, params, action, nil}
  end

  defp settle_for(profile, params, action, nil), do: go_ahead(params, action, profile)

  defp settle_for(profile, params, action, candidate) do
    case BookingPages.locate(profile, candidate) do
      {:ok, page} ->
        if BookingPages.published?(page) or owner_preview?(params, profile),
          do: go_ahead(params, action, profile, page),
          else: not_a_page(params, action, profile)

      {:moved, slug} ->
        {params, action} = at_page(params, action, slug)
        {:redirect, path(params, action, profile.username)}

      :error ->
        not_a_page(params, action, profile)
    end
  end

  defp owner_preview?(params, profile),
    do: PreviewToken.owner?(params["preview_token"], profile.user_id)

  # Under a page route there is nothing; `/<username>/<x>` names a meeting
  # type instead.
  defp not_a_page(params, action, profile) do
    if Map.has_key?(params, "page"),
      do: :not_found,
      else: go_ahead(params, action, profile)
  end

  # On, once the URL is in its stored, lowercase form; otherwise there first.
  defp go_ahead(params, action, profile, page) do
    {settled, settled_action} = at_page(params, action, page.slug)

    if params["username"] == profile.username and candidate(params, action) == page.slug,
      do: {:ok, settled, settled_action, BookingPages.apply_to_profile(profile, page)},
      else: {:redirect, path(settled, settled_action, profile.username)}
  end

  defp go_ahead(params, action, profile) do
    if params["username"] == profile.username,
      do: {:ok, params, action, profile},
      else: {:redirect, path(params, action, profile.username)}
  end

  # `params` and `action` read as the URL beneath the page at `page_slug`, or
  # beneath the host's own page for nil. `/<username>/<x>` without a page
  # route is that page's start page, and `/<username>/<x>/book` its type
  # slugged "book".
  defp at_page(params, :schedule, page_slug) when not is_map_key(params, "page"),
    do: {params |> Map.delete("slug") |> put_page(page_slug), :overview}

  defp at_page(params, :booking, page_slug) when not is_map_key(params, "page"),
    do: {params |> Map.put("slug", "book") |> put_page(page_slug), :schedule}

  defp at_page(params, action, page_slug), do: {put_page(params, page_slug), action}

  defp put_page(params, nil), do: Map.delete(params, "page")
  defp put_page(params, page_slug), do: Map.put(params, "page", page_slug)

  # The path of settled `params` under `username`, with their query.
  defp path(params, action, username) do
    segments = [username | List.wrap(params["page"])] ++ beneath(params, action)

    PathHandlers.with_query(
      "/" <> Enum.map_join(segments, "/", &escape_segment/1),
      PathHandlers.query_params(params)
    )
  end

  defp escape_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp beneath(%{"slug" => slug}, :schedule), do: [slug]
  defp beneath(%{"slug" => slug}, :booking), do: [slug, "book"]
  defp beneath(_params, :confirmation), do: ["thank-you"]
  defp beneath(_params, _overview), do: []
end
