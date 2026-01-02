defmodule TymeslotWeb.Dashboard.VideoSettingsComponent do
  @moduledoc """
  LiveComponent for managing video integrations in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Integrations.Video, as: Video
  alias Tymeslot.Security.VideoInputProcessor
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Components.Dashboard.Integrations.IntegrationCard
  alias TymeslotWeb.Components.Dashboard.Integrations.ProviderCard
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig
  alias TymeslotWeb.Components.DashboardComponents
  alias TymeslotWeb.Helpers.IntegrationProviders
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  require Logger

  @impl true
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    modal_configs = [
      {:delete, false}
    ]

    {:ok,
     socket
     |> ModalHook.mount_modal(modal_configs)
     |> assign(:integrations, [])
     |> assign(:view_mode, :providers)
     |> assign(:config_provider, nil)
     |> assign(:selected_provider, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:testing_connection, nil)
     |> assign(:integration_to_delete, nil)
     |> assign(:available_video_providers, Directory.list(:video))}
  end

  @impl true
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_integrations()

    {:ok, socket}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("back_to_providers", _params, socket) do
    {:noreply,
     socket
     |> assign(:view_mode, :providers)
     |> assign(:config_provider, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})}
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("setup_provider", %{"provider" => provider}, socket) do
    case provider do
      "google_meet" ->
        user_id = socket.assigns.current_user.id

        case Video.oauth_authorization_url(user_id, :google_meet) do
          {:ok, url} ->
            send(self(), {:external_redirect, url})
            {:noreply, assign(socket, :show_provider_modal, false)}

          {:error, error_message} ->
            send(self(), {:flash, {:error, error_message}})
            {:noreply, socket}
        end

      "teams" ->
        user_id = socket.assigns.current_user.id

        case Video.oauth_authorization_url(user_id, :teams) do
          {:ok, url} ->
            send(self(), {:external_redirect, url})
            {:noreply, assign(socket, :show_provider_modal, false)}

          {:error, error_message} ->
            send(self(), {:flash, {:error, error_message}})
            {:noreply, socket}
        end

      _ ->
        # For manual configuration providers, switch to config page mode
        {:noreply,
         socket
         |> assign(:view_mode, :config)
         |> assign(:config_provider, provider)
         |> assign(:form_errors, %{})
         |> assign(:form_values, %{})}
    end
  end

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("provider_changed", %{"value" => provider}, socket) do
    {:noreply, assign(socket, :config_provider, provider)}
  end

  # Field-specific validation handler
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("validate_field", %{"field" => field, "value" => value}, socket) do
    # Update only the specific field in form_values
    form_values = Map.put(socket.assigns.form_values || %{}, field, value)
    # Ensure provider is always included for validation
    form_values = Map.put_new(form_values, "provider", socket.assigns.config_provider)
    socket = assign(socket, :form_values, form_values)

    metadata = get_security_metadata(socket)

    # Validate all form values to get complete error state
    case VideoInputProcessor.validate_video_integration_form(form_values, metadata: metadata) do
      {:ok, _sanitized_params} ->
        {:noreply, assign(socket, :form_errors, %{})}

      {:error, errors} ->
        # Only show error for the field that was just validated
        field_atom = String.to_existing_atom(field)
        field_error = Map.get(errors, field_atom)

        current_errors = socket.assigns.form_errors || %{}

        updated_errors =
          if field_error do
            Map.put(current_errors, field_atom, field_error)
          else
            Map.delete(current_errors, field_atom)
          end

        {:noreply, assign(socket, :form_errors, updated_errors)}
    end
  rescue
    ArgumentError ->
      # If field doesn't exist as atom, just store the value
      {:noreply, socket}
  end

  def handle_event("add_integration", %{"integration" => params}, socket) do
    metadata = get_security_metadata(socket)

    # First validate the video integration form input
    case VideoInputProcessor.validate_video_integration_form(params, metadata: metadata) do
      {:ok, sanitized_params} ->
        # Merge sanitized params with original params (keeping other fields like provider)
        validated_params = Map.merge(params, sanitized_params)

        # Store form values before attempting to add integration
        socket = assign(socket, :form_values, params)

        user_id = socket.assigns.current_user.id
        provider = validated_params["provider"] || socket.assigns.config_provider

        case Video.create_integration(user_id, provider, map_keys_to_atoms(validated_params)) do
          {:ok, _integration} ->
            send(self(), {:flash, {:info, "Video integration added successfully"}})
            send(self(), {:integration_added, :video})

            {:noreply,
             socket
             |> reset_form_state()
             |> load_integrations()
             |> assign(:form_values, %{})}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:form_errors, format_changeset_errors(changeset))
             |> assign(:saving, false)}

          {:error, reason} ->
            # Provider pre-validation error (e.g., connection test) returns a string or reason
            {:noreply,
             socket
             |> assign(:saving, false)
             |> put_provider_specific_error(reason)}
        end

      {:error, validation_errors} ->
        # Keep form values on validation error
        {:noreply,
         socket
         |> assign(:form_errors, validation_errors)
         |> assign(:form_values, params)}
    end
  end

  def handle_event("toggle_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Video.toggle_integration(user_id, normalize_id(id)) do
      {:ok, _} ->
        send(self(), {:flash, {:info, "Integration status updated"}})
        send(self(), {:integration_updated, :video})
        {:noreply, load_integrations(socket)}

      {:error, _} ->
        send(self(), {:flash, {:error, "Failed to update integration status"}})
        {:noreply, socket}
    end
  end

  def handle_event("set_default", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Video.set_default(user_id, normalize_id(id)) do
      {:ok, _} ->
        send(self(), {:flash, {:info, "Default integration updated"}})
        {:noreply, load_integrations(socket)}

      {:error, _} ->
        send(self(), {:flash, {:error, "Failed to set default integration"}})
        {:noreply, socket}
    end
  end

  def handle_event("modal_action", %{"action" => action, "modal" => modal} = params, socket) do
    case {action, modal} do
      {"show", "delete"} ->
        # Standardize: store integration_to_delete as integer
        integration_id =
          case params["id"] do
            nil -> nil
            id when is_integer(id) -> id
            id when is_binary(id) -> String.to_integer(id)
          end

        socket =
          socket
          |> ModalHook.show_modal("delete", params["id"])
          |> assign(:integration_to_delete, integration_id)

        {:noreply, socket}

      {"hide", "delete"} ->
        {:noreply,
         socket
         |> ModalHook.hide_modal("delete")
         |> assign(:integration_to_delete, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_delete_modal", %{"id" => id}, socket) do
    handle_event("modal_action", %{"action" => "show", "modal" => "delete", "id" => id}, socket)
  end

  def handle_event("hide_delete_modal", _params, socket) do
    handle_event("modal_action", %{"action" => "hide", "modal" => "delete"}, socket)
  end

  def handle_event("delete_integration", _params, socket) do
    case socket.assigns.integration_to_delete do
      nil ->
        {:noreply, socket}

      id ->
        user_id = socket.assigns.current_user.id

        case Video.delete_integration(user_id, id) do
          {:ok, :deleted} ->
            send(self(), {:flash, {:info, "Integration deleted successfully"}})
            send(self(), {:integration_removed, :video})

            {:noreply,
             socket
             |> assign(:show_delete_modal, false)
             |> assign(:integration_to_delete, nil)
             |> load_integrations()}

          {:error, _} ->
            send(self(), {:flash, {:error, "Failed to delete integration"}})
            {:noreply, socket}
        end
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    id = normalize_id(id)
    socket = assign(socket, :testing_connection, id)

    case Video.test_connection(user_id, id) do
      {:ok, message} ->
        send(
          self(),
          {:flash, {:info, format_test_success_message(get_provider_name(socket, id), message)}}
        )

        {:noreply, assign(socket, :testing_connection, nil)}

      {:error, reason} when is_binary(reason) ->
        send(self(), {:flash, {:error, reason}})
        {:noreply, assign(socket, :testing_connection, nil)}

      {:error, reason} ->
        send(self(), {:flash, {:error, "Connection test failed: #{inspect(reason)}"}})
        {:noreply, assign(socket, :testing_connection, nil)}
    end
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div>
      <!-- Delete Confirmation Modal -->
      <DeleteIntegrationModal.delete_integration_modal
        id="delete-video-modal"
        show={@show_delete_modal}
        integration_type={:video}
        on_cancel={JS.push("hide_delete_modal", target: @myself)}
        on_confirm={JS.push("delete_integration", target: @myself)}
      />

      <%= if @view_mode == :config do %>
        <!-- Configuration Page Mode -->
        <!-- Configuration Form -->
        <div class="card-glass mb-8">
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
              <p class="text-gray-600">Configuration form not available for this provider.</p>
          <% end %>
        </div>
      <% else %>
        <!-- Providers List Mode -->
        <DashboardComponents.section_header icon={:video} title="Video Integration" />
        
    <!-- Connected Video Providers Section -->
        <%= if @integrations != [] do %>
          <div class="mb-8">
            <div class="flex items-center mb-6">
              <h2 class="text-xl font-semibold text-gray-800">Connected Video Providers</h2>
              <span class="ml-2 bg-blue-100 text-blue-800 text-xs font-medium px-2.5 py-0.5 rounded-full">
                {length(@integrations)}
              </span>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              <%= for integration <- @integrations do %>
                <IntegrationCard.integration_card
                  integration={integration}
                  integration_type={:video}
                  provider_display_name={format_provider_name(integration.provider)}
                  token_expiry_text={format_token_expiry(integration.token_expires_at)}
                  needs_scope_upgrade={false}
                  testing_connection={@testing_connection}
                  myself={@myself}
                />
              <% end %>
            </div>
          </div>
        <% end %>
        
    <!-- Available Video Providers Section -->
        <div class="mb-8">
          <h2 class="text-xl font-semibold text-gray-800 mb-6">Available Video Providers</h2>
          <p class="text-gray-600 mb-6">
            Choose from our supported video providers to enable seamless meeting experiences for your clients.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 mb-6">
            <%= for descp <- @available_video_providers do %>
              <% provider_atom = descp.type %>
              <% provider = Atom.to_string(provider_atom) %>
              <% name = descp.display_name %>
              <% {desc, btn} =
                case provider_atom do
                  :google_meet ->
                    {"Full OAuth integration with automatic room creation", "Connect Google Meet"}

                  :teams ->
                    {"Enterprise OAuth integration with organizational accounts", "Connect Teams"}

                  :mirotalk ->
                    {"Self-hosted peer-to-peer video meetings", "Connect MiroTalk"}

                  :custom ->
                    {"Any video platform with static meeting URLs", "Add Custom Link"}

                  _ ->
                    {"", "Connect"}
                end %>
              <ProviderCard.provider_card
                provider={provider}
                title={name}
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
    </div>
    """
  end

  # Private functions

  defp load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = Video.list_integrations(user_id)
    assign(socket, :integrations, integrations)
  end

  defp reset_form_state(socket) do
    socket
    |> assign(:view_mode, :providers)
    |> assign(:config_provider, nil)
    |> assign(:form_errors, %{})
    |> assign(:saving, false)
  end

  defp map_keys_to_atoms(%{} = map) do
    for {k, v} <- map, into: %{} do
      key =
        cond do
          is_atom(k) ->
            k

          is_binary(k) ->
            try do
              String.to_existing_atom(k)
            rescue
              ArgumentError -> k
            end
        end

      {key, v}
    end
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    ChangesetUtils.get_first_error(changeset)
  end

  defp put_provider_specific_error(socket, reason) do
    # Map a provider test error string to a field when possible (mirotalk)
    cond do
      is_binary(reason) and
          (String.contains?(reason, "Invalid API key") or
             String.contains?(reason, "Authentication failed")) ->
        assign(socket, :form_errors, %{api_key: reason})

      is_binary(reason) and
          (String.contains?(reason, "URL") or String.contains?(reason, "Domain") or
             String.contains?(reason, "endpoint")) ->
        assign(socket, :form_errors, %{base_url: reason})

      is_binary(reason) ->
        assign(socket, :form_errors, %{base_url: reason})

      true ->
        assign(socket, :form_errors, %{base_url: "Connection validation failed"})
    end
  end

  defp normalize_id(id) when is_integer(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_integer(id)

  defp format_test_success_message(provider, message) do
    case provider do
      "mirotalk" -> "✓ MiroTalk connection verified - #{message}"
      "google_meet" -> "✓ Google Meet connection verified - #{message}"
      "teams" -> "✓ Microsoft Teams connection verified - #{message}"
      "custom" -> "✓ Custom provider configured - #{message}"
      _ -> message
    end
  end

  defp get_provider_name(socket, id) do
    case Enum.find(socket.assigns.integrations, &(&1.id == id)) do
      nil -> ""
      integration -> integration.provider
    end
  end

  defp format_provider_name(provider) do
    IntegrationProviders.format_provider_name(:video, provider)
  end

  defp format_token_expiry(expires_at) do
    IntegrationProviders.format_token_expiry(expires_at)
  end

  # Helper function to get security metadata
  defp get_security_metadata(socket) do
    DashboardHelpers.get_security_metadata(socket)
  end
end
