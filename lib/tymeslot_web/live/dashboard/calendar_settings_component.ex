defmodule TymeslotWeb.Dashboard.CalendarSettingsComponent do
  @moduledoc """
  LiveComponent for managing calendar integrations in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.InputValidation, as: CalendarInputValidation
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils
  alias Tymeslot.Utils.SanitizeMerge
  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavReconnectModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Dashboard.CalendarSettings.Components
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  require Logger

  @caldav_providers ProviderConfig.caldav_based_providers()
  @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()

  @impl Phoenix.LiveComponent
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
     |> assign(:health_states, %{})
     |> assign(:available_calendar_providers, Calendar.list_available_providers(:calendar))
     |> assign(:reconnect_integration, nil)
     |> assign(:reconnect_phase, :credentials)
     |> assign(:reconnect_form_values, %{})
     |> assign(:reconnect_form_errors, %{})
     |> assign(:reconnect_discovery_payload, nil)
     |> assign(:reconnect_selected_paths, [])
     |> assign(:reconnect_submitting, false)}
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
  def handle_event("back_to_providers", _params, socket) do
    {:noreply, reset_integration_form_state(socket)}
  end

  def handle_event("validate_field", %{"field" => field} = params, socket) do
    value = Map.get(params, "value", Map.get(socket.assigns.form_values, field, ""))
    form_values = Map.put(socket.assigns.form_values, field, value)
    socket = assign(socket, :form_values, form_values)

    field_atom =
      case field do
        "name" -> :name
        "url" -> :url
        "username" -> :username
        "password" -> :password
        _other -> nil
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
        case CalendarInputValidation.validate_single_field(field_atom, value,
               metadata: socket.assigns.security_metadata
             ) do
          {:ok, _result} ->
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

    case CalendarInputValidation.validate_calendar_discovery(params,
           metadata: socket.assigns.security_metadata,
           provider: provider
         ) do
      {:error, validation_errors} ->
        {:noreply, assign(socket, form_errors: validation_errors, is_saving: false)}

      {:ok, sanitized_params} ->
        user_id = socket.assigns.current_user.id

        case RateLimiter.check_calendar_discovery_rate_limit(user_id) do
          {:error, :rate_limited, message} ->
            Flash.error(message)
            {:noreply, assign(socket, :is_saving, false)}

          :ok ->
            do_discover_calendars(provider, sanitized_params, socket)
        end
    end
  end

  def handle_event("add_integration", %{"integration" => params} = full_params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_integration_write_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        socket = assign(socket, is_saving: true, form_values: params)

        processed_params =
          case Map.get(full_params, "selected_calendars") do
            calendars when is_list(calendars) ->
              selection =
                Calendar.prepare_selection_params(calendars, socket.assigns.discovered_calendars)

              SanitizeMerge.merge(params, selection)

            _other ->
              params
          end

        case Calendar.create_integration_with_validation(
               user_id,
               processed_params,
               metadata: socket.assigns.security_metadata
             ) do
          {:ok, _integration} ->
            send(self(), {:integration_added, :calendar})
            Flash.info("Calendar integration added successfully")
            {:noreply, socket |> reset_integration_form_state() |> load_integrations()}

          {:error, :duplicate_integration} ->
            {:noreply,
             assign(socket,
               form_errors: %{
                 generic: ["A calendar integration with this configuration already exists"]
               },
               is_saving: false
             )}

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
  end

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

  def handle_event("connect_mailbox_org_calendar", _params, socket),
    do: {:noreply, setup_config_view(socket, :mailbox_org)}

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

  def handle_event("reconnect_integration", %{"id" => id}, socket) do
    with {:ok, int_id} <- parse_int(id),
         {:ok, integration} <- Calendar.get_integration(int_id, socket.assigns.current_user.id) do
      handle_reconnect_by_provider(integration, socket)
    else
      :error ->
        Flash.error("Invalid calendar ID")
        {:noreply, socket}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("close_reconnect_modal", _params, socket) do
    {:noreply, reset_reconnect_assigns(socket)}
  end

  def handle_event("reconnect_caldav_discover", %{"reconnect" => params}, socket) do
    integration = socket.assigns.reconnect_integration
    user_id = socket.assigns.current_user.id
    socket = assign(socket, :reconnect_submitting, true)

    case Calendar.reconnect_caldav_integration(user_id, integration.id, params) do
      {:ok, :needs_calendar_selection, payload} ->
        selected_paths = Enum.filter(integration.calendar_paths || [], &is_binary/1)

        {:noreply,
         socket
         |> assign(:reconnect_phase, :calendar_selection)
         |> assign(:reconnect_discovery_payload, payload)
         |> assign(:reconnect_selected_paths, selected_paths)
         |> assign(:reconnect_form_errors, %{})
         |> assign(:reconnect_submitting, false)}

      {:error, :invalid_credentials} ->
        {:noreply,
         socket
         |> assign(:reconnect_form_errors, %{
           generic: ["Could not sign in with those credentials"]
         })
         |> assign(:reconnect_form_values, params)
         |> assign(:reconnect_submitting, false)}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, assign(socket, :reconnect_submitting, false)}

      {:error, reason} when is_binary(reason) ->
        {:noreply,
         socket
         |> assign(:reconnect_form_errors, %{generic: [reason]})
         |> assign(:reconnect_form_values, params)
         |> assign(:reconnect_submitting, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:reconnect_form_errors, %{
           generic: [Calendar.connection_error_message(reason)]
         })
         |> assign(:reconnect_form_values, params)
         |> assign(:reconnect_submitting, false)}
    end
  end

  def handle_event("reconnect_caldav_submit", _params, socket)
      when is_nil(socket.assigns.reconnect_discovery_payload) do
    Flash.error("Session expired. Please start the reconnect process again.")
    {:noreply, reset_reconnect_assigns(socket)}
  end

  def handle_event("reconnect_caldav_submit", params, socket) do
    integration = socket.assigns.reconnect_integration
    user_id = socket.assigns.current_user.id
    payload = socket.assigns.reconnect_discovery_payload
    selected_paths = params |> Map.get("selected_paths", []) |> List.wrap()
    socket = assign(socket, :reconnect_submitting, true)

    case Calendar.finalise_caldav_reconnect(user_id, integration.id, %{
           payload: payload,
           selected_paths: selected_paths
         }) do
      {:ok, _updated} ->
        send(self(), {:integration_updated, :calendar})
        Flash.info("Calendar reconnected")

        {:noreply,
         socket
         |> reset_reconnect_assigns()
         |> load_integrations()}

      {:error, :no_calendars_selected} ->
        {:noreply,
         socket
         |> assign(:reconnect_form_errors, %{
           generic: ["Please select at least one calendar to sync."]
         })
         |> assign(:reconnect_submitting, false)}

      {:error, :not_found} ->
        Flash.error("Integration not found")
        {:noreply, reset_reconnect_assigns(socket)}

      {:error, {:changeset, cs}} ->
        Flash.error("Could not save: #{ChangesetUtils.get_first_error(cs)}")
        {:noreply, assign(socket, :reconnect_submitting, false)}
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

  defp do_discover_calendars(provider, sanitized_params, socket) do
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
  end

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

  defp normalize_provider(p) when p in @caldav_providers, do: p

  defp normalize_provider(p) when is_binary(p) do
    atom = String.to_existing_atom(p)
    if atom in @caldav_providers, do: atom, else: :caldav
  rescue
    ArgumentError -> :caldav
  end

  defp normalize_provider(_other_provider), do: :caldav

  defp format_refresh_failures(names) when length(names) <= 3 do
    Enum.join(names, ", ")
  end

  defp format_refresh_failures(names) do
    shown = names |> Enum.take(3) |> Enum.join(", ")
    "#{shown} and #{length(names) - 3} more"
  end

  defp handle_reconnect_by_provider(%{provider: "google"}, socket) do
    case Calendar.initiate_google_oauth(socket.assigns.current_user.id) do
      {:ok, url} ->
        send(self(), {:external_redirect, url})
        {:noreply, socket}

      {:error, msg} ->
        Flash.error(msg)
        {:noreply, socket}
    end
  end

  defp handle_reconnect_by_provider(%{provider: "outlook"}, socket) do
    case Calendar.initiate_outlook_oauth(socket.assigns.current_user.id) do
      {:ok, url} ->
        send(self(), {:external_redirect, url})
        {:noreply, socket}

      {:error, msg} ->
        Flash.error(msg)
        {:noreply, socket}
    end
  end

  defp handle_reconnect_by_provider(%{provider: provider} = integration, socket)
       when provider in @caldav_provider_strings do
    {:noreply,
     socket
     |> assign(:reconnect_integration, integration)
     |> assign(:reconnect_phase, :credentials)
     |> assign(:reconnect_form_errors, %{})
     |> assign(:reconnect_form_values, %{
       "url" => integration.base_url || "",
       "username" => integration.username || "",
       "password" => ""
     })
     |> assign(:reconnect_discovery_payload, nil)
     |> assign(:reconnect_selected_paths, [])
     |> assign(:reconnect_submitting, false)}
  end

  defp handle_reconnect_by_provider(%{provider: provider}, socket) do
    Logger.warning("Reconnect requested for unsupported provider", provider: provider)
    Flash.error("Reconnect is not supported for this provider yet.")
    {:noreply, socket}
  end

  defp reset_reconnect_assigns(socket) do
    socket
    |> assign(:reconnect_integration, nil)
    |> assign(:reconnect_phase, :credentials)
    |> assign(:reconnect_discovery_payload, nil)
    |> assign(:reconnect_selected_paths, [])
    |> assign(:reconnect_form_errors, %{})
    |> assign(:reconnect_submitting, false)
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
        :if={@reconnect_integration}
        module={CaldavReconnectModal}
        id="caldav-reconnect-modal"
        integration={@reconnect_integration}
        phase={@reconnect_phase}
        form_values={@reconnect_form_values}
        form_errors={@reconnect_form_errors}
        discovery_payload={@reconnect_discovery_payload}
        selected_paths={@reconnect_selected_paths}
        is_submitting={@reconnect_submitting}
        parent_target={@myself}
      />
    </div>
    """
  end
end
