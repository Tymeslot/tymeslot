defmodule TymeslotWeb.Hooks.DashboardInitHook do
  @moduledoc """
  Consolidated hook for dashboard initialization.
  Handles onboarding checks, profile loading, and common dashboard state.
  """
  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  require Logger
  import Phoenix.LiveView
  import Phoenix.Component
  alias Tymeslot.Auth
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.DatabaseSchemas.ProfileSchema
  alias Tymeslot.Features
  alias Tymeslot.Profiles

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        # Let authentication hooks handle missing user
        {:cont, socket}

      !Auth.onboarding_completed?(user) ->
        {:halt, redirect(socket, to: ~p"/onboarding")}

      true ->
        profile =
          Profiles.get_profile(user.id) ||
            %ProfileSchema{user_id: user.id}

        integration_status = DashboardContext.get_integration_status(user.id)

        automations_allowed =
          case Features.check_access(user.id, :automations_allowed) do
            :ok -> true
            {:error, _reason} -> false
          end

        socket =
          socket
          |> assign(:profile, profile)
          |> assign(:integration_status, integration_status)
          |> assign(:automations_allowed, automations_allowed)
          |> assign_new(:saving, fn -> false end)

        {:cont, socket}
    end
  end
end
