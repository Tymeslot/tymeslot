defmodule TymeslotWeb.Hooks.DashboardInitHook do
  @moduledoc """
  Consolidated hook for dashboard initialization.
  Handles onboarding checks, profile loading, and common dashboard state.
  """
  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  import Phoenix.LiveView
  import Phoenix.Component
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Dashboard.ExtensionSchema
  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user]

    cond do
      is_nil(user) ->
        # Let authentication hooks handle missing user
        {:cont, socket}

      !Onboarding.onboarding_completed?(user) ->
        {:halt, redirect(socket, to: ~p"/onboarding")}

      true ->
        mount_dashboard_data(user, socket)
    end
  end

  defp mount_dashboard_data(user, socket) do
    {profile, integration_status} = load_profile_and_integration_status(user, socket)

    # Read extension/feature config once at mount so components receive stable assigns
    # rather than calling Application.get_env on every render.
    socket =
      socket
      |> assign(:profile, profile)
      |> assign(:integration_status, integration_status)
      # Resolved once here rather than per component: every dashboard surface
      # renders the same clock, and a meeting list must not query per row.
      # AppLocaleHook runs before this one, so the ambient locale is already the
      # organiser's when it supplies the preset.
      |> assign(
        :time_format,
        CalendarGrid.get_user_time_format(user.id, Gettext.get_locale(TymeslotWeb.Gettext))
      )
      |> assign(:payments_allowed, payments_allowed?(user.id))
      |> assign_new(:saving, fn -> false end)
      |> assign_new(:saving_timer_ref, fn -> nil end)
      |> assign(
        :sidebar_extensions,
        :tymeslot
        |> Application.get_env(:dashboard_sidebar_extensions, [])
        |> ExtensionSchema.filter_valid()
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

  # The static render is thrown away the moment the socket connects, but
  # several dashboard surfaces (onboarding checklist, theme lock overlay,
  # calendar-connect banner) branch on `integration_status` in that first
  # paint too, so it must be the real value there, not the all-false
  # default — otherwise a fully set-up host sees a false "setup incomplete"
  # flash before the socket connects. `DashboardContext.get_integration_status/1`
  # is cache-backed (5 minutes), so fetching it synchronously here is cheap.
  defp load_profile_and_integration_status(user, socket) do
    if connected?(socket) do
      fetch_profile_and_integration_status(user)
    else
      {load_profile!(user), DashboardContext.get_integration_status(user.id)}
    end
  end

  defp fetch_profile_and_integration_status(user) do
    # Load profile and integration status concurrently — they are independent
    profile_task =
      Tasks.async_nolink(Tymeslot.TaskSupervisor, fn -> load_profile!(user) end)

    integration_task =
      Tasks.async_nolink(Tymeslot.TaskSupervisor, fn ->
        DashboardContext.get_integration_status(user.id)
      end)

    results = Task.yield_many([profile_task, integration_task], :timer.seconds(5))

    Enum.each(results, fn
      {task, nil} -> Task.shutdown(task, :brutal_kill)
      _result -> :ok
    end)

    # Unlike integration status, the profile has no stand-in: every section
    # keys its queries off `profile.id` and every save writes the row, so an
    # unsaved struct only moves the crash to the host's first save and throws
    # away what they typed. A load that timed out or failed is retried here,
    # synchronously like the time-format and payments reads below; if the
    # database cannot answer that either, the mount fails and LiveView rejoins.
    profile =
      case Enum.at(results, 0) do
        {_task, {:ok, value}} -> value
        _timeout_or_error -> load_profile!(user)
      end

    integration_status =
      case Enum.at(results, 1) do
        {_task, {:ok, value}} -> value
        _timeout_or_error -> DashboardContext.default_integration_status()
      end

    {profile, integration_status}
  end

  # Signup and onboarding both create the profile, so a finished host without
  # one is an anomaly; creating it here as onboarding does keeps the dashboard
  # on a stored row instead of one that cannot be saved.
  defp load_profile!(user) do
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    profile
  end

  defp payments_allowed?(user_id), do: Features.meeting_payments_allowed?(user_id)
end
