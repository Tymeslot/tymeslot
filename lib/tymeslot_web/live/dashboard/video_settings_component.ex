defmodule TymeslotWeb.Dashboard.VideoSettingsComponent do
  @moduledoc """
  LiveComponent for managing video integrations in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.DatabaseQueries.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.InputValidation, as: VideoInputValidation
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Components.Dashboard.Integrations.ProviderCard
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.EditVideoIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.VideoRow
  alias TymeslotWeb.Helpers.IntegrationProviders
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  require Logger

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:integrations, [])
     |> assign(:view_mode, :providers)
     |> assign(:config_provider, nil)
     |> assign(:selected_provider, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:testing_connection, nil)
     |> assign(:health_states, %{})
     |> assign(:available_video_providers, Directory.list(:video))}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_integrations()

    {:ok, socket}
  end

  def handle_event("track_form_change", %{"integration" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("back_to_providers", _params, socket) do
    {:noreply,
     socket
     |> assign(:view_mode, :providers)
     |> assign(:config_provider, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})}
  end

  def handle_event("setup_provider", %{"provider" => provider}, socket) do
    case provider do
      "google_meet" ->
        initiate_oauth(socket, :google_meet)

      "teams" ->
        initiate_oauth(socket, :teams)

      _other ->
        {:noreply,
         socket
         |> assign(:view_mode, :config)
         |> assign(:config_provider, provider)
         |> assign(:form_errors, %{})
         |> assign(:form_values, %{})}
    end
  end

  def handle_event("provider_changed", %{"value" => provider}, socket) do
    {:noreply,
     socket
     |> assign(:config_provider, provider)
     |> assign(:form_errors, %{})}
  end

  def handle_event("validate_field", %{"field" => field} = params, socket) do
    value = Map.get(params, "value", Map.get(socket.assigns.form_values || %{}, field, ""))

    form_values =
      (socket.assigns.form_values || %{})
      |> Map.put(field, value)
      |> Map.put("provider", socket.assigns.config_provider)

    socket = assign(socket, :form_values, form_values)

    metadata = DashboardHelpers.get_security_metadata(socket)
    field_atom = map_field_to_atom(field)

    if String.trim(to_string(value)) == "" do
      current_errors = socket.assigns.form_errors || %{}

      {:noreply,
       assign(
         socket,
         :form_errors,
         FormValidationHelpers.delete_field_error(current_errors, field_atom)
       )}
    else
      case VideoInputValidation.validate_single_field(field_atom, value, metadata: metadata) do
        {:ok, _sanitized_value} ->
          current_errors = socket.assigns.form_errors || %{}

          {:noreply,
           assign(
             socket,
             :form_errors,
             FormValidationHelpers.delete_field_error(current_errors, field_atom)
           )}

        {:error, error} ->
          current_errors = socket.assigns.form_errors || %{}

          {:noreply,
           assign(
             socket,
             :form_errors,
             Map.put(current_errors, field_atom, error)
           )}
      end
    end
  end

  def handle_event("add_integration", %{"integration" => params}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      socket = assign(socket, :saving, true)
      metadata = DashboardHelpers.get_security_metadata(socket)

      case VideoInputValidation.validate_video_integration_form(params, metadata: metadata) do
        {:ok, sanitized_params} ->
          validated_params = Map.merge(params, sanitized_params)
          provider = validated_params["provider"] || socket.assigns.config_provider

          if is_nil(provider) do
            {:noreply,
             socket
             |> assign(:form_errors, %{base: "Please select a provider"})
             |> assign(:saving, false)}
          else
            case Video.create_integration(user_id, provider, map_keys_to_atoms(validated_params)) do
              {:ok, _integration} ->
                notify_parent({:flash, {:info, "Video integration added successfully"}})
                notify_parent({:integration_added, :video})

                {:noreply,
                 socket
                 |> reset_form_state()
                 |> load_integrations()
                 |> assign(:form_values, %{})}

              {:error, %Ecto.Changeset{} = changeset} ->
                {:noreply,
                 socket
                 |> assign(:form_errors, ChangesetUtils.get_first_error(changeset))
                 |> assign(:saving, false)}

              {:error, :duplicate_integration} ->
                {:noreply,
                 socket
                 |> assign(:form_errors, %{
                   base: "A video integration with this configuration already exists"
                 })
                 |> assign(:saving, false)}

              {:error, reason} ->
                {:noreply,
                 socket
                 |> assign(:saving, false)
                 |> assign(:form_errors, IntegrationProviders.reason_to_form_errors(reason))}
            end
          end

        {:error, validation_errors} ->
          {:noreply,
           socket
           |> assign(:form_errors, validation_errors)
           |> assign(:form_values, params)}
      end
    end)
  end

  def handle_event("reconnect_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      integration_id = normalize_id(id)
      integration = Enum.find(socket.assigns.integrations, &(&1.id == integration_id))

      if integration do
        case Video.oauth_reconnect_url(user_id, integration) do
          {:ok, url} ->
            {:noreply, redirect(socket, external: url)}

          {:error, _reason} ->
            notify_parent({:flash, {:error, "Failed to reconnect. Please try again."}})
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    end)
  end

  def handle_event("toggle_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      case Video.toggle_integration(user_id, normalize_id(id)) do
        {:ok, _result} ->
          notify_parent({:flash, {:info, "Integration status updated"}})
          notify_parent({:integration_updated, :video})
          {:noreply, load_integrations(socket)}

        {:error, _reason} ->
          notify_parent({:flash, {:error, "Failed to update integration status"}})
          {:noreply, socket}
      end
    end)
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      int_id = normalize_id(id)
      provider = get_provider_name(socket, int_id)

      socket =
        socket
        |> assign(:testing_connection, int_id)
        |> start_async(:test_connection, fn ->
          {provider, Video.test_connection(user_id, int_id)}
        end)

      {:noreply, socket}
    end)
  end

  @impl Phoenix.LiveComponent
  def handle_async(:test_connection, {:ok, {provider, result}}, socket) do
    case result do
      {:ok, message} ->
        notify_parent(
          {:flash, {:info, IntegrationProviders.format_test_success_message(provider, message)}}
        )

      {:error, reason} when is_binary(reason) ->
        notify_parent({:flash, {:error, reason}})

      {:error, reason} ->
        notify_parent({:flash, {:error, "Connection test failed: #{inspect(reason)}"}})
    end

    {:noreply, assign(socket, :testing_connection, nil)}
  end

  def handle_async(:test_connection, {:exit, reason}, socket) do
    notify_parent({:flash, {:error, "Connection test failed unexpectedly: #{inspect(reason)}"}})
    {:noreply, assign(socket, :testing_connection, nil)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header icon={:video} title="Video Integration" />

      <%= if @view_mode == :config do %>
        <!-- Configuration Page Mode -->
        <div
          id="video-config-view"
          phx-hook="ScrollReset"
          data-action={@config_provider}
          class="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500"
        >
          <div class="flex items-center gap-6 bg-white p-6 rounded-token-3xl border-2 border-tymeslot-50 shadow-sm">
            <button
              phx-click="back_to_providers"
              phx-target={@myself}
              class="flex items-center gap-2 px-4 py-2 rounded-token-xl bg-tymeslot-50 text-tymeslot-600 font-bold hover:bg-tymeslot-100 transition-all"
            >
              <.icon name="hero-arrow-left" class="w-5 h-5" />
              Back
            </button>

            <div class="h-8 w-px bg-tymeslot-100"></div>

            <.section_header
              level={2}
              icon={:video}
              title={"Setup #{IntegrationProviders.format_provider_name(:video, @config_provider)}"}
            />
          </div>

          <div class="card-glass">
            <%= case @config_provider do %>
              <% "mirotalk" -> %>
                <.live_component
                  module={MirotalkConfig}
                  id="mirotalk-config"
                  target={@myself}
                  form_errors={@form_errors}
                  form_values={@form_values}
                  saving={@saving}
                />
              <% "custom" -> %>
                <.live_component
                  module={CustomConfig}
                  id="custom-config"
                  target={@myself}
                  form_errors={@form_errors}
                  form_values={@form_values}
                  saving={@saving}
                />
              <% _ -> %>
                <p class="text-tymeslot-500 font-medium">Configuration form not available for this provider.</p>
            <% end %>
          </div>
        </div>
      <% else %>
        <!-- Connected Video Providers Section -->
        <%= if @integrations != [] do %>
          <% {active_integrations, inactive_integrations} = Enum.split_with(@integrations, & &1.is_active) %>
          <% show_section_headers = active_integrations != [] and inactive_integrations != [] %>

          <div class="space-y-6">
            <!-- Active Video Integrations -->
            <%= if active_integrations != [] do %>
              <div class="space-y-3">
                <%= if show_section_headers do %>
                  <h3 class="text-lg font-bold text-turquoise-800">Active Video Integrations</h3>
                <% end %>

                <%= for integration <- active_integrations do %>
                  <VideoRow.video_row
                    integration={integration}
                    testing_connection={@testing_connection}
                    myself={@myself}
                    health_state={Map.get(@health_states, integration.id)}
                  />
                <% end %>
              </div>
            <% end %>

            <!-- Inactive Video Integrations -->
            <%= if inactive_integrations != [] do %>
              <div class="space-y-3">
                <%= if show_section_headers do %>
                  <h3 class="text-lg font-semibold text-tymeslot-600">Inactive Video Integrations</h3>
                <% end %>

                <%= for integration <- inactive_integrations do %>
                  <VideoRow.video_row
                    integration={integration}
                    testing_connection={@testing_connection}
                    myself={@myself}
                    health_state={Map.get(@health_states, integration.id)}
                  />
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <!-- Available Video Providers Section -->
        <div class="space-y-8 mt-12">
          <div class="max-w-4xl">
            <.section_header level={2} title="Available Providers" />
            <p class="text-tymeslot-500 font-medium text-token-lg ml-1">
              Choose from our supported video providers to enable seamless meeting experiences for your clients.
            </p>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
            <%= for descp <- @available_video_providers do %>
              <% provider = Atom.to_string(descp.type) %>
              <% {desc, btn} = get_provider_display_info(descp.type) %>
              <ProviderCard.provider_card
                provider={provider}
                title={descp.display_name}
                description={desc}
                button_text={btn}
                click_event="setup_provider"
                target={@myself}
                provider_value={provider}
              />
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Edit Integration Modal -->
      <.live_component
        module={EditVideoIntegrationModal}
        id="edit-video-modal"
        integrations={@integrations}
        current_user={@current_user}
      />

      <!-- Delete Confirmation Modal -->
      <.live_component
        module={DeleteIntegrationModal}
        id="delete-video-modal"
        integration_type={:video}
        current_user={@current_user}
      />
    </div>
    """
  end

  # Private functions

  defp with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    notify_parent({:flash, {:error, message}})
    {:noreply, socket}
  end

  defp with_rate_limit(:ok, _socket, action), do: action.()

  defp load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = Video.list_integrations(user_id)

    health_states =
      user_id
      |> IntegrationHealthStateQueries.list_unhealthy_for_user()
      |> Enum.filter(&(&1.integration_type == "video"))
      |> Map.new(fn s -> {s.integration_id, Monitor.from_db_record(s)} end)

    socket
    |> assign(:integrations, integrations)
    |> assign(:health_states, health_states)
  end

  defp reset_form_state(socket) do
    socket
    |> assign(:view_mode, :providers)
    |> assign(:config_provider, nil)
    |> assign(:form_errors, %{})
    |> assign(:saving, false)
  end

  defp initiate_oauth(socket, provider) do
    user_id = socket.assigns.current_user.id

    case Video.oauth_authorization_url(user_id, provider) do
      {:ok, url} ->
        notify_parent({:external_redirect, url})
        {:noreply, socket}

      {:error, error_message} ->
        notify_parent({:flash, {:error, error_message}})
        {:noreply, socket}
    end
  end

  defp notify_parent(msg), do: send(self(), msg)

  defp map_keys_to_atoms(%{} = map) do
    for {k, v} <- map, into: %{} do
      key =
        cond do
          is_atom(k) -> k
          is_binary(k) -> try_string_to_atom(k)
        end

      {key, v}
    end
  end

  defp try_string_to_atom(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)

  defp map_field_to_atom(field) do
    case field do
      "name" -> :name
      "base_url" -> :base_url
      "api_key" -> :api_key
      "custom_meeting_url" -> :custom_meeting_url
      _other -> :unknown
    end
  end

  defp get_provider_name(socket, id) do
    case Enum.find(socket.assigns.integrations, &(&1.id == id)) do
      nil -> ""
      integration -> integration.provider
    end
  end

  defp get_provider_display_info(provider_atom) do
    case provider_atom do
      :google_meet ->
        {"Full OAuth integration with automatic room creation", "Connect Google Meet"}

      :teams ->
        {"Enterprise OAuth integration with organizational accounts", "Connect Teams"}

      :mirotalk ->
        {"Self-hosted peer-to-peer video meetings", "Connect MiroTalk"}

      :custom ->
        {"Any video platform with static meeting URLs", "Add Custom Link"}

      _other ->
        {"", "Connect"}
    end
  end
end
