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
  alias Tymeslot.Features
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema

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
        mount_dashboard_data(user, socket)
    end
  end

  defp mount_dashboard_data(user, socket) do
    # Load profile and integration status concurrently — they are independent
    profile_task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        Profiles.get_profile(user.id) || %ProfileSchema{user_id: user.id}
      end)

    integration_task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        DashboardContext.get_integration_status(user.id)
      end)

    results = Task.yield_many([profile_task, integration_task], :timer.seconds(5))

    Enum.each(results, fn
      {task, nil} -> Task.shutdown(task, :brutal_kill)
      _result -> :ok
    end)

    profile =
      case Enum.at(results, 0) do
        {_task, {:ok, value}} -> value
        _timeout_or_error -> %ProfileSchema{user_id: user.id}
      end

    integration_status =
      case Enum.at(results, 1) do
        {_task, {:ok, value}} -> value
        _timeout_or_error -> DashboardContext.default_integration_status()
      end

    # Read extension/feature config once at mount so components receive stable assigns
    # rather than calling Application.get_env on every render.
    socket =
      socket
      |> assign(:profile, profile)
      |> assign(:integration_status, integration_status)
      |> assign(:payments_allowed, payments_allowed?(user.id))
      |> assign_new(:saving, fn -> false end)
      |> assign_new(:saving_timer_ref, fn -> nil end)
      |> assign(
        :sidebar_extensions,
        Application.get_env(:tymeslot, :dashboard_sidebar_extensions, [])
      )
      |> assign(
        :feature_placeholder_components,
        Application.get_env(:tymeslot, :feature_placeholder_components, %{})
      )
      |> assign(
        :dashboard_action_components,
        Application.get_env(:tymeslot, :dashboard_action_components, %{})
      )
      |> assign(
        :dashboard_feature_gates,
        Application.get_env(:tymeslot, :dashboard_feature_gates, %{})
      )

    {:cont, socket}
  end

  # Whether the host can reach the payments dashboard. Mirrors the gate in
  # `PaymentsHandlers`: both `:ok` and `{:error, :stripe_required}` mean the
  # feature is on (Stripe just isn't connected yet), so the sidebar link shows.
  defp payments_allowed?(user_id) do
    case Features.check_access(user_id, :meeting_payments) do
      :ok -> true
      {:error, :stripe_required} -> true
      _other -> false
    end
  end
end
