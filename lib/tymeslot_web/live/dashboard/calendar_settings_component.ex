defmodule TymeslotWeb.Dashboard.CalendarSettingsComponent do
  @moduledoc """
  LiveComponent for managing calendar integrations in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Diagnostics
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavReconnectModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Dashboard.CalendarSettings.Components
  alias TymeslotWeb.Dashboard.CalendarSettings.ConfigViewComponent
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash

  @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:integrations, [])
     |> assign(:view, :providers)
     |> assign(:selected_provider, nil)
     |> assign(:testing_integration_id, nil)
     |> assign(:is_refreshing, false)
     |> assign(:validating_integration_id, nil)
     |> assign(:health_states, %{})
     |> assign(:available_calendar_providers, Calendar.list_available_providers(:calendar))}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_integrations()
      |> assign_new(:security_metadata, fn -> DashboardHelpers.get_security_metadata(socket) end)

    {:ok, socket}
  end

  # --- Event Handlers ---

  @impl Phoenix.LiveComponent
  def handle_event("toggle_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with :ok <- RateLimiter.check_integration_write_rate_limit(user_id),
         {:ok, int_id} <- parse_int(id),
         {:ok, _result} <- Calendar.toggle_integration(int_id, user_id) do
      Flash.info("Calendar status updated")
      send(self(), {:integration_updated, :calendar})
      {:noreply, load_integrations(socket)}
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :duplicate_account} ->
        Flash.error("Cannot reactivate — another active integration already uses this account")
        {:noreply, socket}

      {:error, reason} ->
        Flash.error("Failed to update status: #{inspect(reason)}")
        {:noreply, socket}

      :error ->
        Flash.error("Invalid calendar ID")
        {:noreply, socket}
    end
  end

  def handle_event("connect_provider", %{"provider" => "google"}, socket) do
    case Calendar.initiate_google_oauth(socket.assigns.current_user.id) do
      {:ok, url} -> send(self(), {:external_redirect, url})
      {:error, msg} -> Flash.error(msg)
    end

    {:noreply, socket}
  end

  def handle_event("connect_provider", %{"provider" => "outlook"}, socket) do
    case Calendar.initiate_outlook_oauth(socket.assigns.current_user.id) do
      {:ok, url} -> send(self(), {:external_redirect, url})
      {:error, msg} -> Flash.error(msg)
    end

    {:noreply, socket}
  end

  def handle_event("connect_provider", %{"provider" => provider}, socket)
      when provider in @caldav_provider_strings do
    {:noreply, setup_config_view(socket, String.to_existing_atom(provider))}
  end

  def handle_event("connect_provider", _params, socket) do
    Flash.error("Unsupported provider")
    {:noreply, socket}
  end

  def handle_event("refresh_all_calendars", _params, socket) do
    if socket.assigns.is_refreshing do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id

      case RateLimiter.check_calendar_refresh_rate_limit(user_id) do
        {:error, :rate_limited, message} ->
          Flash.error(message)
          {:noreply, socket}

        :ok ->
          active = Enum.filter(socket.assigns.integrations, & &1.is_active)

          if active == [] do
            {:noreply, assign(socket, :is_refreshing, false)}
          else
            {:noreply,
             socket
             |> assign(:is_refreshing, true)
             |> start_async(:refresh_calendars, fn ->
               active
               |> Task.async_stream(
                 fn integration ->
                   {integration.name, Calendar.update_integration_with_discovery(integration)}
                 end,
                 max_concurrency: 5,
                 timeout: 30_000
               )
               |> Enum.to_list()
             end)}
          end
      end
    end
  end

  def handle_event(
        "toggle_calendar_selection",
        %{"integration_id" => id, "calendar_id" => cal_id},
        socket
      ) do
    user_id = socket.assigns.current_user.id

    # Re-fetch the integration by id before updating: the struct in
    # socket assigns can be stale if the row was deleted between mount
    # and this click, and CalendarIntegrationSchema has no
    # optimistic_lock — Repo.update on a stale struct returns
    # {:ok, stale_struct} (0 rows affected, no exception) and the user
    # would see a silent no-op.
    with :ok <- RateLimiter.check_integration_write_rate_limit(user_id),
         {:ok, int_id} <- parse_int(id),
         {:ok, integration} <- Calendar.get_integration(int_id, user_id),
         {:ok, _result} <- Calendar.toggle_calendar_selection(integration, cal_id) do
      {:noreply, load_integrations(socket)}
    else
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error("This calendar integration is no longer available.")
        {:noreply, load_integrations(socket)}

      _other ->
        Flash.error("Failed to update selection")
        {:noreply, socket}
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_caldav_connection_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        with {:ok, int_id} <- parse_int(id),
             socket = assign(socket, :testing_integration_id, int_id),
             {:ok, integration} <-
               Calendar.get_integration(int_id, socket.assigns.current_user.id),
             {:ok, message} <- Diagnostics.test_connection(integration) do
          Flash.info(message)
          {:noreply, assign(socket, :testing_integration_id, nil)}
        else
          {:error, :not_found} ->
            Flash.error("Integration not found")
            {:noreply, assign(socket, :testing_integration_id, nil)}

          {:error, reason} ->
            Flash.error("Connection test failed: #{inspect(reason)}")
            {:noreply, assign(socket, :testing_integration_id, nil)}

          :error ->
            Flash.error("Invalid calendar ID")
            {:noreply, socket}
        end
    end
  end

  def handle_event("upgrade_google_scope", %{"id" => id}, socket) do
    with {:ok, int_id} <- parse_int(id),
         {:ok, url} <-
           Calendar.initiate_google_scope_upgrade(socket.assigns.current_user.id, int_id) do
      send(self(), {:external_redirect, url})
      {:noreply, socket}
    else
      {:error, :invalid_provider} ->
        Flash.error("Not a Google Calendar")
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, socket}

      {:error, msg} when is_binary(msg) ->
        Flash.error(msg)
        {:noreply, socket}

      _other ->
        Flash.error("Invalid request")
        {:noreply, socket}
    end
  end

  # --- Async Handlers ---

  @impl Phoenix.LiveComponent
  def handle_async(:refresh_calendars, {:ok, results}, socket) do
    {successes, failed_names} =
      Enum.reduce(results, {0, []}, fn
        {:ok, {_name, {:ok, _result}}}, {s, f} -> {s + 1, f}
        {:ok, {name, _error}}, {s, f} -> {s, [name | f]}
        _other, {s, f} -> {s, ["unknown" | f]}
      end)

    failures = length(failed_names)

    cond do
      failures == 0 ->
        Flash.info("All calendars refreshed successfully")

      successes > 0 ->
        detail = format_refresh_failures(Enum.reverse(failed_names))
        Flash.error("#{successes} refreshed, #{failures} failed: #{detail}")

      true ->
        Flash.error("All calendar refreshes failed.")
    end

    {:noreply, socket |> assign(:is_refreshing, false) |> load_integrations()}
  end

  def handle_async(:refresh_calendars, {:error, _reason}, socket) do
    Flash.error("Refresh process failed unexpectedly.")
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  # --- Private Helpers ---

  defp load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = Calendar.list_integrations(user_id)

    health_states =
      user_id
      |> IntegrationHealthStateQueries.list_unhealthy_for_user()
      |> Enum.filter(&(&1.integration_type == "calendar"))
      |> Map.new(fn s -> {s.integration_id, Monitor.from_db_record(s)} end)

    socket
    |> assign(:integrations, integrations)
    |> assign(:health_states, health_states)
  end

  defp setup_config_view(socket, provider) do
    assign(socket, view: :config, selected_provider: provider)
  end

  defp format_refresh_failures(names) when length(names) <= 3 do
    Enum.join(names, ", ")
  end

  defp format_refresh_failures(names) do
    shown = names |> Enum.take(3) |> Enum.join(", ")
    "#{shown} and #{length(names) - 3} more"
  end

  defp parse_int(id) when is_integer(id), do: {:ok, id}

  defp parse_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _other -> :error
    end
  end

  defp parse_int(_arg), do: :error

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-12 pb-24">
      <.section_header icon={:calendar} title="Calendar Settings" />

      <%= if @view == :config do %>
        <.live_component
          module={ConfigViewComponent}
          id="calendar-config-view-component"
          selected_provider={@selected_provider}
          current_user={@current_user}
          security_metadata={@security_metadata}
        />
      <% else %>
        <Components.connected_calendars_section
          integrations={@integrations}
          testing_integration_id={@testing_integration_id}
          validating_integration_id={@validating_integration_id}
          is_refreshing={@is_refreshing}
          myself={@myself}
          health_states={@health_states}
        />

        <Components.available_providers_section
          available_calendar_providers={@available_calendar_providers}
          integrations={@integrations}
          myself={@myself}
        />
      <% end %>

      <.live_component
        module={DeleteIntegrationModal}
        id="delete-calendar-modal"
        integration_type={:calendar}
        current_user={@current_user}
      />

      <.live_component
        module={CaldavReconnectModal}
        id="caldav-reconnect-modal"
        current_user={@current_user}
      />
    </div>
    """
  end
end
