defmodule TymeslotWeb.Live.Scheduling.PreviewMode do
  @moduledoc """
  The owner-preview URL contract: what a preview URL means, and how to build one.

  Three query parameters take part, and they are deliberately not
  interchangeable:

    * `?preview=true` claims preview *display* mode. It is unauthenticated and
      trivially forgeable, so it tunes rendering only (the `iframe_embed.js`
      standalone bail-out, the CSP `frame-ancestors 'self'` pin) and never by
      itself authorises anything.

    * `?preview_token=` is the verified, owner-bound authorisation to SIMULATE
      a booking rather than persist it. See `PreviewToken`.

    * `?theme=` selects which theme renders. That is *all* it does. It is a
      plain display selector on a public page, reachable by anyone who types
      it, so it must never be read as a claim about who is viewing.

  That last point is the reason this module exists. The rule used to be spelled
  out twice, in `ThemeUtils.assign_theme_with_preview/2` and in
  `Themes.Core.Context.from_params/2`, and both copies counted a bare `?theme=`
  as a preview. Because the locale switcher put `theme=` into every redirect,
  any visitor who changed the language was silently reclassified as a previewer
  and their booking was failed closed (issue #84). One named predicate, used by
  both call sites, is what keeps that from drifting back.
  """

  alias Tymeslot.Bookings.Policy
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  @doc """
  True when the URL claims preview display mode.

  Note what is absent: `?theme=` does not count. A theme selector on a public
  page says nothing about who is viewing it.
  """
  @spec claimed?(map()) :: boolean()
  def claimed?(params) when is_map(params), do: Map.has_key?(params, "preview")
  def claimed?(_params), do: false

  @doc """
  Builds the path to an owner preview of `username`'s booking page.

  Carries both halves of the contract: the display claim and a freshly signed,
  owner-bound token, so the page renders as a preview *and* simulates bookings
  instead of persisting them. Building only one half is the bug this replaces;
  the two dashboard entry points used to link `?theme=<id>` with no token, so
  the owner's own test booking hit the fail-closed branch and vanished.

  Pass `:theme` to preview a theme other than the stored one.
  """
  @spec owner_path(String.t(), integer(), keyword()) :: String.t()
  def owner_path(username, user_id, opts \\ [])
      when is_binary(username) and is_integer(user_id) do
    query =
      %{"preview" => "true", "preview_token" => PreviewToken.sign(user_id)}
      |> put_theme(Keyword.get(opts, :theme))
      |> URI.encode_query()

    "/#{username}?#{query}"
  end

  @doc """
  Absolute-URL form of `owner_path/3`, for the onboarding preview iframe.
  """
  @spec owner_url(String.t(), integer(), keyword()) :: String.t()
  def owner_url(username, user_id, opts \\ []) do
    Policy.app_url() <> owner_path(username, user_id, opts)
  end

  defp put_theme(query, theme) when theme in [nil, ""], do: query
  defp put_theme(query, theme), do: Map.put(query, "theme", to_string(theme))
end
