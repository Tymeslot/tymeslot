defmodule TymeslotWeb.Hooks.ThemeHook do
  @moduledoc """
  LiveView hook to handle theme assignment for scheduling and meeting management pages.
  Sets a validated theme_id in assigns before the layout renders: the `?theme=` override
  when it names a registered theme, else the organiser's theme, else the default.
  """

  import Phoenix.Component

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
    Registry.requested_theme_id(params) || organiser_theme_id(params["username"]) ||
      Catalog.default_id()
  end

  defp organiser_theme_id(username) when is_binary(username) do
    case Profiles.get_profile_by_username(username) do
      %{booking_theme: theme_id} when is_binary(theme_id) ->
        if Registry.valid_theme_id?(theme_id), do: theme_id

      _no_profile ->
        nil
    end
  end

  defp organiser_theme_id(_no_username), do: nil
end
