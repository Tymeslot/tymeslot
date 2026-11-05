defmodule TymeslotWeb.Hooks.ThemeHook do
  @moduledoc """
  LiveView hook to handle theme assignment for scheduling and meeting management pages.
  Sets a validated theme_id in assigns before the layout renders: the `?theme=` override
  when it names a registered theme, else the organiser's theme, else the default.

  On the booking routes it runs after `TymeslotWeb.Live.Scheduling.PageAddress`
  and takes the organiser that hook settled, so it queries nothing of its own.
  """

  import Phoenix.Component

  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.Registry

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, params, _session, socket) do
    {:cont, assign(socket, :theme_id, resolve_theme_id(params, socket.assigns))}
  end

  # A requested theme wins, then the organiser's, then the default. Anything
  # the registry does not know is skipped, never assigned.
  defp resolve_theme_id(params, assigns) do
    Registry.requested_theme_id(params) || organiser_theme_id(params, assigns) ||
      Catalog.default_id()
  end

  defp organiser_theme_id(params, assigns) do
    case organiser(params, assigns) do
      %{booking_theme: theme_id} when is_binary(theme_id) ->
        if Registry.valid_theme_id?(theme_id), do: theme_id

      _no_profile ->
        nil
    end
  end

  # On a booking URL, the organiser `PageAddress` settled, wearing the page
  # the URL is under when there is one; elsewhere (meeting management, poll
  # voting), the username's own profile.
  defp organiser(_params, %{page_address: %{organiser: organiser}}), do: organiser

  defp organiser(%{"username" => username}, _assigns) when is_binary(username),
    do: Profiles.get_profile_by_username(username)

  defp organiser(_params, _assigns), do: nil
end
