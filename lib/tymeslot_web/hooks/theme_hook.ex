defmodule TymeslotWeb.Hooks.ThemeHook do
  @moduledoc """
  LiveView hook to handle theme assignment for scheduling and meeting management pages.
  Sets a validated theme_id in assigns before the layout renders: the `?theme=` override
  when it names a registered theme, else the organiser's theme, else the default.
  """

  import Phoenix.Component

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.Registry

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, _session, socket) do
    {:cont, assign(socket, :theme_id, resolve_theme_id(params))}
  end

  # A requested theme wins, then the organiser's, then the default. Anything
  # the registry does not know is skipped, never assigned.
  defp resolve_theme_id(params) do
    Registry.requested_theme_id(params) || organiser_theme_id(params) || Catalog.default_id()
  end

  # The theme of the start page the URL is under: one of the organiser's
  # booking pages (`/<username>/<page>`, or `/<username>/<x>` when `x` is a
  # page's slug), otherwise the organiser's own.
  defp organiser_theme_id(%{"username" => username} = params) when is_binary(username) do
    page_slug = params["page"] || params["slug"]

    case username |> Profiles.get_profile_by_username() |> BookingPages.presented_at(page_slug) do
      %{booking_theme: theme_id} when is_binary(theme_id) ->
        if Registry.valid_theme_id?(theme_id), do: theme_id

      _no_profile ->
        nil
    end
  end

  defp organiser_theme_id(_no_username), do: nil
end
