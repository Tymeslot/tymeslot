defmodule TymeslotWeb.Dashboard.CalendarSettingsComponent do
  @moduledoc """
  LiveComponent for managing calendar integrations in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Security.CalendarInputProcessor
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Dashboard.CalendarSettings.Components
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:integrations, [])
     |> assign(:view, :providers)
     |> assign(:selected_provider, nil)
     |> assign(:discovered_calendars, [])
     |> assign(:show_calendar_selection, false)
     |> assign(:discovery_credentials, %{})
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:is_saving, false)
     |> assign(:testing_integration_id, nil)
     |> assign(:is_refreshing, false)
     |> assign(:validating_integration_id, nil)
     |> assign(:available_calendar_providers, Calendar.list_available_providers(:calendar))}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_integrations()
      |> assign_new(:security_metadata, fn -> DashboardHelpers.get_security_metadata(socket) end)

    # Handle events from parent-driven modal interactions if any
    socket =
      case {assigns[:event], assigns[:params]} do
        {"add_integration", %{"integration" => params}} ->
          {_, socket} = handle_event("add_integration", %{"integration" => params}, socket)
          socket

        _ ->
          socket
      end

    {:ok, socket}
  end

  # --- Event Handlers ---

  @impl true
  def handle_event("back_to_providers", _params, socket) do
    {:noreply, reset_integration_form_state(socket)}
  end

  def handle_event("validate_field", %{"field" => field, "value" => value}, socket) do
    form_values = Map.put(socket.assigns.form_values, field, value)
    socket = assign(socket, :form_values, form_values)

    field_atom =
      case field do
        "name" -> :name
        "url" -> :url
        "username" -> :username
        "password" -> :password
        _ -> nil
      end

    if field_atom do
      if String.trim(to_string(value)) == "" do
        {:noreply,
         assign(
           socket,
           :form_errors,
           FormValidationHelpers.delete_field_error(socket.assigns.form_errors, field_atom)
         )}
      else
        case CalendarInputProcessor.validate_single_field(field_atom, value,
               metadata: socket.assigns.security_metadata
             ) do
          {:ok, _} ->
            {:noreply,
             assign(
               socket,
               :form_errors,
               FormValidationHelpers.delete_field_error(socket.assigns.form_errors, field_atom)
             )}

          {:error, error} ->
            {:noreply,
             assign(
               socket,
               :form_errors,
               Map.put(socket.assigns.form_errors, field_atom, error)
             )}
        end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("track_form_change", %{"integration" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  def handle_event("discover_calendars", %{"integration" => params}, socket) do
    provider = normalize_provider(params["provider"] || socket.assigns.selected_provider)

    socket =
      socket
      |> assign(:is_saving, true)
      |> assign(:form_values, params)
      |> assign(:form_errors, %{})

    case CalendarInputProcessor.validate_calendar_discovery(params,
           metadata: socket.assigns.security_metadata,
           provider: provider
         ) do
      {:ok, sanitized_params} ->
        case Calendar.discover_and_filter_calendars(
               provider,
               sanitized_params["url"],
               sanitized_params["username"],
               sanitized_params["password"]
             ) do
          {:ok, %{calendars: calendars, discovery_credentials: credentials}} ->
            {:noreply,
             socket
             |> assign(:discovered_calendars, calendars)
             |> assign(:discovery_credentials, credentials)
             |> assign(:show_calendar_selection, true)
             |> assign(:is_saving, false)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:form_errors, %{discovery: Calendar.normalize_discovery_error(reason)})
             |> assign(:is_saving, false)}
        end

      {:error, validation_errors} ->
        {:noreply, assign(socket, form_errors: validation_errors, is_saving: false)}
    end
  end

  def handle_event("add_integration", %{"integration" => params} = full_params, socket) do
    socket = assign(socket, is_saving: true, form_values: params)

    processed_params =
      case Map.get(full_params, "selected_calendars") do
        calendars when is_list(calendars) ->
          selection =
            Calendar.prepare_selection_params(calendars, socket.assigns.discovered_calendars)

          Map.merge(params, selection)

        _ ->
          params
      end

    case Calendar.create_integration_with_validation(
           socket.assigns.current_user.id,
           processed_params,
           metadata: socket.assigns.security_metadata
         ) do
      {:ok, _integration} ->
        send(self(), {:integration_added, :calendar})
        Flash.info("Calendar integration added successfully")
        {:noreply, socket |> reset_integration_form_state() |> load_integrations()}

      {:error, {:form_errors, errors}} ->
        {:noreply, assign(socket, form_errors: errors, is_saving: false)}

      {:error, {:changeset, changeset}} ->
        {:noreply,
         assign(socket,
           form_errors: %{generic: [ChangesetUtils.get_first_error(changeset)]},
           is_saving: false
         )}
    end
  end

  def handle_event("toggle_integration", %{"id" => id}, socket) do
    with {:ok, int_id} <- parse_int(id),
         {:ok, _} <- Calendar.toggle_integration(int_id, socket.assigns.current_user.id) do
      Flash.info("Calendar status updated")
      send(self(), {:integration_updated, :calendar})
      {:noreply, load_integrations(socket)}
    else
      {:error, reason} ->
        Flash.error("Failed to update status: #{inspect(reason)}")
        {:noreply, socket}

      :error ->
        Flash.error("Invalid calendar ID")
        {:noreply, socket}
    end
  end

  def handle_event("connect_google_calendar", _params, socket) do
    case Calendar.initiate_google_oauth(socket.assigns.current_user.id) do
      {:ok, url} -> send(self(), {:external_redirect, url})
      {:error, msg} -> Flash.error(msg)
    end

    {:noreply, socket}
  end

  def handle_event("connect_outlook_calendar", _params, socket) do
    case Calendar.initiate_outlook_oauth(socket.assigns.current_user.id) do
      {:ok, url} -> send(self(), {:external_redirect, url})
      {:error, msg} -> Flash.error(msg)
    end

    {:noreply, socket}
  end

  def handle_event("connect_nextcloud_calendar", _params, socket),
    do: {:noreply, setup_config_view(socket, :nextcloud)}

  def handle_event("connect_caldav_calendar", _params, socket),
    do: {:noreply, setup_config_view(socket, :caldav)}

  def handle_event("connect_radicale_calendar", _params, socket),
    do: {:noreply, setup_config_view(socket, :radicale)}

  def handle_event("connect_zimbra_calendar", _params, socket),
    do: {:noreply, setup_config_view(socket, :zimbra)}

  def handle_event("refresh_all_calendars", _params, socket) do
    if socket.assigns.is_refreshing do
      {:noreply, socket}
    else
      active = Enum.filter(socket.assigns.integrations, & &1.is_active)

      if active == [] do
        {:noreply, assign(socket, :is_refreshing, false)}
      else
        {:noreply,
         socket
         |> assign(:is_refreshing, true)
         |> start_async(:refresh_calendars, fn ->
           active
           |> Task.async_stream(&Calendar.update_integration_with_discovery/1,
             max_concurrency: 5,
             timeout: 30_000
           )
           |> Enum.to_list()
         end)}
      end
    end
  end

  def handle_event(
        "toggle_calendar_selection",
        %{"integration_id" => id, "calendar_id" => cal_id},
        socket
      ) do
    with {:ok, int_id} <- parse_int(id),
         %{} = integration <-
           Enum.find(socket.assigns.integrations, &(&1.id == int_id)),
         {:ok, _} <- Calendar.toggle_calendar_selection(integration, cal_id) do
      {:noreply, load_integrations(socket)}
    else
      _ ->
        Flash.error("Failed to update selection")
        {:noreply, socket}
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    with {:ok, int_id} <- parse_int(id),
         socket = assign(socket, :testing_integration_id, int_id),
         {:ok, integration} <- Calendar.get_integration(int_id, socket.assigns.current_user.id),
         {:ok, message} <- Calendar.test_connection(integration) do
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

      _ ->
        Flash.error("Invalid request")
        {:noreply, socket}
    end
  end

  # --- Async Handlers ---

  @impl true
  def handle_async(:refresh_calendars, {:ok, results}, socket) do
    {successes, failures} =
      Enum.reduce(results, {0, 0}, fn
        {:ok, {:ok, _}}, {s, f} -> {s + 1, f}
        _other, {s, f} -> {s, f + 1}
      end)

    cond do
      failures == 0 ->
        Flash.info("All calendars refreshed successfully")

      successes > 0 ->
        Flash.error("#{successes} refreshed, #{failures} failed. Check connections.")

      true ->
        Flash.error("All calendar refreshes failed.")
    end

    {:noreply, socket |> assign(:is_refreshing, false) |> load_integrations()}
  end

  def handle_async(:refresh_calendars, {:error, _}, socket) do
    Flash.error("Refresh process failed unexpectedly.")
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  # --- Private Helpers ---

  defp load_integrations(socket) do
    assign(socket, :integrations, Calendar.list_integrations(socket.assigns.current_user.id))
  end

  defp setup_config_view(socket, provider) do
    socket
    |> assign(view: :config, selected_provider: provider)
    |> reset_discovery_state()
  end

  defp reset_integration_form_state(socket) do
    socket
    |> assign(view: :providers, selected_provider: nil)
    |> reset_discovery_state()
  end

  defp reset_discovery_state(socket) do
    assign(socket,
      discovered_calendars: [],
      show_calendar_selection: false,
      discovery_credentials: %{},
      form_errors: %{},
      form_values: %{},
      is_saving: false
    )
  end

  defp normalize_provider(p) when p in [:nextcloud, :radicale, :caldav], do: p
  defp normalize_provider("nextcloud"), do: :nextcloud
  defp normalize_provider("radicale"), do: :radicale
  defp normalize_provider("caldav"), do: :caldav
  defp normalize_provider(_), do: :caldav

  defp parse_int(id) when is_integer(id), do: {:ok, id}

  defp parse_int(id) when is_binary(id) do
    case Integer.parse(id) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp parse_int(_), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-12 pb-24">
      <.section_header icon={:calendar} title="Calendar Settings" />

      <%= if @view == :config do %>
        <Components.config_view
          selected_provider={@selected_provider}
          myself={@myself}
          security_metadata={@security_metadata}
          form_errors={@form_errors}
          form_values={@form_values}
          discovered_calendars={@discovered_calendars}
          show_calendar_selection={@show_calendar_selection}
          discovery_credentials={@discovery_credentials}
          is_saving={@is_saving}
        />
      <% else %>
        <Components.connected_calendars_section
          integrations={@integrations}
          testing_integration_id={@testing_integration_id}
          validating_integration_id={@validating_integration_id}
          is_refreshing={@is_refreshing}
          myself={@myself}
        />

        <Components.available_providers_section
          available_calendar_providers={@available_calendar_providers}
          myself={@myself}
        />
      <% end %>

      <.live_component
        module={DeleteIntegrationModal}
        id="delete-calendar-modal"
        integration_type={:calendar}
        current_user={@current_user}
      />
    </div>
    """
  end
end
