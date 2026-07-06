defmodule TymeslotWeb.Dashboard.VideoSettingsComponent do
  @moduledoc """
  LiveComponent for managing video integrations in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.InputValidation, as: VideoInputValidation
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils
  alias Tymeslot.Utils.SanitizeMerge
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ProviderPickerModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.EditVideoIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig
  alias TymeslotWeb.Dashboard.VideoSettings.Components
  alias TymeslotWeb.Helpers.IntegrationProviders
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:integrations, [])
     |> assign(:config_provider, nil)
     |> assign(:selected_provider, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:testing_connection, nil)
     |> assign(:health_states, %{})
     |> assign(:show_picker, false)
     |> assign(:available_video_providers, Directory.list(:video))}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> maybe_load_integrations(assigns)

    {:ok, socket}
  end

  # The integrations hub already loads the video list and health states for
  # its active tab child (one query per hub render instead of two) and
  # passes them down as the `integrations`/`health_states` props. Reuse them
  # when present; fall back to loading independently otherwise — e.g. when
  # mounted standalone via the `:video_integration` dashboard action, or when
  # a `send_update/2` targets us with a partial assign (those always want a
  # fresh reload, matching prior behaviour).
  defp maybe_load_integrations(socket, %{
         integrations: _integrations,
         health_states: _health_states
       }),
       do: socket

  defp maybe_load_integrations(socket, _assigns), do: load_integrations(socket)

  @impl Phoenix.LiveComponent
  def handle_event("show_picker", _params, socket) do
    {:noreply, assign(socket, :show_picker, true)}
  end

  def handle_event("hide_picker", _params, socket) do
    {:noreply, assign(socket, show_picker: false, config_provider: nil)}
  end

  def handle_event("track_form_change", %{"integration" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  def handle_event("back_to_providers", _params, socket) do
    {:noreply,
     socket
     |> assign(:config_provider, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})}
  end

  def handle_event("setup_provider", %{"provider" => provider}, socket) do
    case ProviderConfig.parse(provider) do
      {:ok, provider_atom} when provider_atom != :none ->
        if Directory.oauth?(:video, provider_atom) == true do
          initiate_oauth(socket, provider_atom)
        else
          {:noreply,
           socket
           |> assign(:config_provider, provider)
           |> assign(:show_picker, true)
           |> assign(:form_errors, %{})
           |> assign(:form_values, %{})}
        end

      _other ->
        {:noreply, socket}
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
          validated_params = SanitizeMerge.merge(params, sanitized_params)
          provider = validated_params["provider"] || socket.assigns.config_provider

          if is_nil(provider) do
            {:noreply,
             socket
             |> assign(:form_errors, %{base: "Please select a provider"})
             |> assign(:saving, false)}
          else
            handle_create_result(
              Video.create_integration(user_id, provider, map_keys_to_atoms(validated_params)),
              socket
            )
          end

        {:error, validation_errors} ->
          {:noreply,
           socket
           |> assign(:form_errors, validation_errors)
           |> assign(:form_values, params)
           |> assign(:saving, false)}
      end
    end)
  end

  def handle_event("reconnect_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      case normalize_id(id) do
        nil ->
          {:noreply, socket}

        integration_id ->
          case Video.get_integration(user_id, integration_id) do
            {:ok, integration} ->
              case Video.oauth_reconnect_url(user_id, integration) do
                {:ok, url} ->
                  {:noreply, redirect(socket, external: url)}

                {:error, _reason} ->
                  notify_parent({:flash, {:error, "Failed to reconnect. Please try again."}})
                  {:noreply, socket}
              end

            {:error, :not_found} ->
              {:noreply, socket}
          end
      end
    end)
  end

  def handle_event("toggle_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      case normalize_id(id) do
        nil ->
          {:noreply, socket}

        integration_id ->
          case Video.toggle_integration(user_id, integration_id) do
            {:ok, _result} ->
              notify_parent({:flash, {:info, "Integration status updated"}})
              notify_parent({:integration_updated, :video})
              {:noreply, load_integrations(socket)}

            {:error, :duplicate_account} ->
              notify_parent(
                {:flash,
                 {:error,
                  "Cannot reactivate — another active integration already uses this account"}}
              )

              {:noreply, socket}

            {:error, _reason} ->
              notify_parent({:flash, {:error, "Failed to update integration status"}})
              {:noreply, socket}
          end
      end
    end)
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      case normalize_id(id) do
        nil ->
          {:noreply, socket}

        int_id ->
          provider = get_provider_name(socket, int_id)

          socket =
            socket
            |> assign(:testing_connection, int_id)
            |> start_async(:test_connection, fn ->
              {provider, Video.test_connection(user_id, int_id)}
            end)

          {:noreply, socket}
      end
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
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <.section_header icon="hero-video-camera" title="Video Integration" />
        <button
          phx-click="show_picker"
          phx-target={@myself}
          class="inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-4 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600 shrink-0"
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Connect a video provider
        </button>
      </div>

      <div>
        <%!-- Connected Video Providers Section --%>
        <%= if @integrations == [] do %>
          <div class="card-glass p-10 text-center">
            <div class="mx-auto mb-4 flex h-14 w-14 items-center justify-center rounded-token-2xl bg-turquoise-50 text-turquoise-500">
              <.icon name="hero-video-camera" class="h-7 w-7" />
            </div>
            <h3 class="text-token-lg font-semibold text-tymeslot-800">
              No video providers connected yet
            </h3>
            <p class="mx-auto mt-1 max-w-md text-token-sm text-tymeslot-500">
              Connect one so online meetings get a video link added automatically when
              they're booked.
            </p>
            <button
              phx-click="show_picker"
              phx-target={@myself}
              class="mt-5 inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-4 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> Connect a video provider
            </button>
          </div>
        <% else %>
          <% {active_integrations, inactive_integrations} = Enum.split_with(@integrations, & &1.is_active) %>
          <% show_section_headers = active_integrations != [] and inactive_integrations != [] %>

          <div class="space-y-6">
            <%!-- Active Video Integrations --%>
            <%= if active_integrations != [] do %>
              <div class="space-y-3">
                <%= if show_section_headers do %>
                  <h3 class="text-lg font-bold text-turquoise-800">Active Video Integrations</h3>
                <% end %>

                <%= for integration <- active_integrations do %>
                  <Components.video_connection_row
                    integration={integration}
                    testing_connection={@testing_connection}
                    myself={@myself}
                    health_state={Map.get(@health_states, integration.id)}
                  />
                <% end %>
              </div>
            <% end %>

            <%!-- Inactive Video Integrations --%>
            <%= if inactive_integrations != [] do %>
              <div class="space-y-3">
                <%= if show_section_headers do %>
                  <h3 class="text-lg font-semibold text-tymeslot-600">Inactive Video Integrations</h3>
                <% end %>

                <%= for integration <- inactive_integrations do %>
                  <Components.video_connection_row
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

        <ProviderPickerModal.provider_picker_modal
          id="video-provider-picker"
          show={@show_picker}
          title="Connect a video provider"
          subtitle="Add a video link to online meetings automatically when they're booked."
          target={@myself}
          on_cancel={JS.push("hide_picker", target: @myself)}
          groups={picker_groups(@available_video_providers, @integrations)}
          config_active={@config_provider != nil}
          back_event="back_to_providers"
        >
          <:config>
            <.live_component
              :if={@config_provider == "mirotalk"}
              module={MirotalkConfig}
              id="mirotalk-config"
              target={@myself}
              form_errors={@form_errors}
              form_values={@form_values}
              saving={@saving}
            />
            <.live_component
              :if={@config_provider == "custom"}
              module={CustomConfig}
              id="custom-config"
              target={@myself}
              form_errors={@form_errors}
              form_values={@form_values}
              saving={@saving}
            />
          </:config>
        </ProviderPickerModal.provider_picker_modal>
      </div>

      <%!-- Edit Integration Modal --%>
      <.live_component
        module={EditVideoIntegrationModal}
        id="edit-video-modal"
        integrations={@integrations}
        current_user={@current_user}
      />

      <%!-- Delete Confirmation Modal --%>
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

  defp handle_create_result({:ok, _integration}, socket) do
    notify_parent({:flash, {:info, "Video integration added successfully"}})
    notify_parent({:integration_added, :video})

    {:noreply,
     socket
     |> reset_form_state()
     |> assign(:show_picker, false)
     |> load_integrations()
     |> assign(:form_values, %{})}
  end

  defp handle_create_result({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply,
     socket
     |> assign(:form_errors, ChangesetUtils.get_first_error(changeset))
     |> assign(:saving, false)}
  end

  defp handle_create_result({:error, :duplicate_integration}, socket) do
    {:noreply,
     socket
     |> assign(:form_errors, %{
       base: "A video integration with this configuration already exists"
     })
     |> assign(:saving, false)}
  end

  defp handle_create_result({:error, reason}, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> assign(:form_errors, IntegrationProviders.reason_to_form_errors(reason))}
  end

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
      |> HealthCheck.list_unhealthy_for_user()
      |> Enum.filter(&(&1.integration_type == "video"))
      |> Map.new(fn s -> {s.integration_id, Monitor.from_db_record(s)} end)

    socket
    |> assign(:integrations, integrations)
    |> assign(:health_states, health_states)
  end

  defp reset_form_state(socket) do
    socket
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

  # Builds the single-group provider list for the picker modal.
  defp picker_groups(available, integrations) do
    entries = Enum.map(available, &provider_entry(&1, integrations))
    [%{label: nil, providers: entries}]
  end

  defp provider_entry(descriptor, integrations) do
    provider = Atom.to_string(descriptor.type)

    %{
      provider: provider,
      title: descriptor.display_name,
      description: descriptor.description,
      click_event: "setup_provider",
      connected?: Enum.any?(integrations, &(&1.provider == provider))
    }
  end

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

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _other -> nil
    end
  end

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
end
