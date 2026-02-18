defmodule TymeslotWeb.Dashboard.AutomationSettingsComponent do
  @moduledoc """
  LiveComponent for managing automation in the dashboard.
  Currently supports webhooks, with plans for Slack and other integrations.
  """
  use TymeslotWeb, :live_component

  require Logger

  alias Phoenix.LiveView.JS
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.InputValidation, as: WebhookInputValidation
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Automation.Components
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Dashboard.Automation.Modals
  alias TymeslotWeb.Dashboard.Automation.WebhookFormComponent
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    modal_configs = [
      {:delete, false},
      {:deliveries, false},
      {:regenerate_token, false}
    ]

    {:ok,
     socket
     |> ModalHook.mount_modal(modal_configs)
     |> assign(:webhooks, [])
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:testing_connection, nil)
     |> assign(:webhook_to_delete, nil)
     |> assign(:selected_webhook, nil)
     |> assign(:deliveries, [])
     |> assign(:delivery_stats, nil)
     |> assign(:available_events, Webhooks.available_events())
     |> assign(:show_webhook_form, false)
     |> assign(:webhook_form_mode, :create)
     |> assign(:webhook_form_data, nil)
     |> assign(:webhook_form_timestamp, nil)}
  end

  @impl Phoenix.LiveComponent
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_webhooks()

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("show_webhook_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_webhook_form, true)
     |> assign(:webhook_form_mode, :create)
     |> assign(:webhook_form_data, nil)
     |> assign(:webhook_form_timestamp, System.system_time())
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{
       "name" => "",
       "url" => "",
       "events" => []
     })}
  end

  def handle_event("close_webhook_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_webhook_form, false)
     |> assign(:webhook_form_data, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})}
  end

  def handle_event("validate_field", %{"field" => field, "value" => value}, socket) do
    metadata = AutomationHelpers.get_security_metadata(socket)
    form_values = Map.put(socket.assigns.form_values, field, value)

    updated_errors =
      if is_binary(value) and String.trim(value) == "" do
        atom_field = FormValidationHelpers.atomize_field(field, ~w(name url events))
        FormValidationHelpers.delete_field_error(socket.assigns.form_errors, atom_field)
      else
        AutomationHelpers.validate_field(
          form_values,
          socket.assigns.form_errors,
          field,
          value,
          metadata
        )
      end

    {:noreply,
     socket
     |> assign(:form_values, form_values)
     |> assign(:form_errors, updated_errors)}
  end

  def handle_event("validate_field", %{"field" => field} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.form_values, field, "")
    handle_event("validate_field", %{"field" => field, "value" => value}, socket)
  end

  def handle_event("toggle_event", %{"event" => event}, socket) do
    form_values = AutomationHelpers.toggle_event(socket.assigns.form_values, event)

    # Trigger validation for the events field
    metadata = AutomationHelpers.get_security_metadata(socket)

    updated_errors =
      AutomationHelpers.validate_field(
        form_values,
        socket.assigns.form_errors,
        "events",
        Map.get(form_values, "events"),
        metadata
      )

    {:noreply,
     socket
     |> assign(:form_values, form_values)
     |> assign(:form_errors, updated_errors)}
  end

  def handle_event("create_webhook", %{"webhook" => params}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_webhook_write_rate_limit(user_id), socket, fn ->
      do_webhook_write(params, socket, &Webhooks.create_webhook(user_id, &1), "created")
    end)
  end

  def handle_event("show_edit_webhook_form", %{"id" => id}, socket) do
    case get_webhook_for_user(socket, id) do
      {:ok, webhook} ->
        {:noreply,
         socket
         |> assign(:show_webhook_form, true)
         |> assign(:webhook_form_mode, :edit)
         |> assign(:webhook_form_data, webhook)
         |> assign(:webhook_form_timestamp, System.system_time())
         |> assign(:form_errors, %{})
         |> assign(:form_values, %{
           "name" => webhook.name,
           "url" => webhook.url,
           "events" => webhook.events
         })}

      {:error, _reason} ->
        Flash.error("Webhook not found")
        {:noreply, socket}
    end
  end

  def handle_event("update_webhook", %{"webhook" => params}, socket) do
    case socket.assigns.webhook_form_data do
      nil ->
        {:noreply, socket}

      webhook ->
        user_id = socket.assigns.current_user.id

        with_rate_limit(RateLimiter.check_webhook_write_rate_limit(user_id), socket, fn ->
          do_webhook_write(params, socket, &Webhooks.update_webhook(webhook, &1), "updated")
        end)
    end
  end

  def handle_event("show_delete_modal", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> ModalHook.show_modal(:delete)
     |> assign(:webhook_to_delete, AutomationHelpers.parse_id(id))}
  end

  def handle_event("hide_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:delete)
     |> assign(:webhook_to_delete, nil)}
  end

  def handle_event("delete_webhook", _params, socket) do
    case socket.assigns.webhook_to_delete do
      nil ->
        {:noreply, socket}

      id ->
        case get_webhook_for_user(socket, id) do
          {:ok, webhook} ->
            case Webhooks.delete_webhook(webhook) do
              {:ok, _result} ->
                Flash.info("Webhook deleted successfully")

                {:noreply,
                 socket
                 |> ModalHook.hide_modal(:delete)
                 |> assign(:webhook_to_delete, nil)
                 |> load_webhooks()}

              {:error, _reason} ->
                Flash.error("Failed to delete webhook")
                {:noreply, socket}
            end

          {:error, _reason} ->
            Flash.error("Webhook not found")
            {:noreply, socket}
        end
    end
  end

  def handle_event("toggle_webhook", %{"id" => id}, socket) do
    case get_webhook_for_user(socket, id) do
      {:ok, webhook} ->
        case Webhooks.toggle_webhook(webhook) do
          {:ok, _result} ->
            Flash.info("Webhook status updated")
            {:noreply, load_webhooks(socket)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to update webhook status")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Webhook not found")
        {:noreply, socket}
    end
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_webhook_test_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        webhook_id = AutomationHelpers.parse_id(id)
        socket = assign(socket, :testing_connection, webhook_id)

        case get_webhook_for_user(socket, id) do
          {:ok, webhook} ->
            case Webhooks.test_webhook_connection(webhook.url, webhook.webhook_token) do
              :ok ->
                Flash.info("Webhook test successful! Check your endpoint.")
                {:noreply, assign(socket, :testing_connection, nil)}

              {:error, reason} ->
                Flash.error("Test failed: #{reason}")
                {:noreply, assign(socket, :testing_connection, nil)}
            end

          {:error, _reason} ->
            Flash.error("Webhook not found")
            {:noreply, assign(socket, :testing_connection, nil)}
        end
    end
  end

  def handle_event("show_deliveries", %{"id" => id}, socket) do
    case get_webhook_for_user(socket, id) do
      {:ok, webhook} ->
        deliveries = Webhooks.list_deliveries(webhook.id, limit: 50)
        stats = Webhooks.get_delivery_stats(webhook.id, days: 7)

        {:noreply,
         socket
         |> ModalHook.show_modal(:deliveries)
         |> assign(:selected_webhook, webhook)
         |> assign(:deliveries, deliveries)
         |> assign(:delivery_stats, stats)}

      {:error, _reason} ->
        Flash.error("Webhook not found")
        {:noreply, socket}
    end
  end

  def handle_event("show_regenerate_token_modal", %{"id" => id}, socket) do
    case get_webhook_for_user(socket, id) do
      {:ok, webhook} ->
        {:noreply,
         socket
         |> ModalHook.show_modal(:regenerate_token)
         |> assign(:selected_webhook, webhook)}

      {:error, _reason} ->
        Flash.error("Webhook not found")
        {:noreply, socket}
    end
  end

  def handle_event("hide_regenerate_token_modal", _params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:regenerate_token)
     |> assign(:selected_webhook, nil)}
  end

  def handle_event("regenerate_token", _params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_webhook_token_regen_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        do_regenerate_token(socket)
    end
  end

  def handle_event("hide_deliveries", _params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:deliveries)
     |> assign(:selected_webhook, nil)
     |> assign(:deliveries, [])
     |> assign(:delivery_stats, nil)}
  end

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <!-- Modals (Always rendered so they can be triggered from anywhere) -->
      <Modals.delete_webhook_modal
        show={@show_delete_modal}
        on_cancel={JS.push("hide_delete_modal", target: @myself)}
        on_confirm={JS.push("delete_webhook", target: @myself)}
      />

      <%= if @show_deliveries_modal do %>
        <Modals.deliveries_modal
          show={@show_deliveries_modal}
          webhook={@selected_webhook}
          deliveries={@deliveries}
          stats={@delivery_stats}
          on_close={JS.push("hide_deliveries", target: @myself)}
        />
      <% end %>

      <Modals.regenerate_token_modal
        show={@show_regenerate_token_modal}
        on_cancel={JS.push("hide_regenerate_token_modal", target: @myself)}
        on_confirm={JS.push("regenerate_token", target: @myself)}
      />

      <%= if @show_webhook_form do %>
        <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
          <.live_component
            module={WebhookFormComponent}
            id={"webhook-form-#{@webhook_form_mode}-#{@webhook_form_timestamp}"}
            mode={@webhook_form_mode}
            webhook={@webhook_form_data}
            form_values={@form_values}
            form_errors={@form_errors}
            saving={@saving}
            parent_component={@myself}
          />
        </div>
      <% else %>
        <.section_header icon={:webhook} title="Automation" />

        <!-- Tabs Navigation -->
        <div class="flex flex-wrap gap-4 bg-tymeslot-50/50 p-2 rounded-[2rem] border-2 border-tymeslot-50 mb-10">
          <div
            class="flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-white border-white text-turquoise-600 shadow-xl shadow-tymeslot-200/50 scale-[1.02] cursor-default"
          >
            <IconComponents.icon name={:webhook} class="w-5 h-5" />
            <span>Webhooks</span>
          </div>

          <div
            class="flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 opacity-60 cursor-not-allowed"
          >
            <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
              <path d="M6 12.5C6 11.1193 7.11929 10 8.5 10C9.88071 10 11 11.1193 11 12.5C11 13.8807 9.88071 15 8.5 15C7.11929 15 6 13.8807 6 12.5Z" />
              <path fill-rule="evenodd" clip-rule="evenodd" d="M2 12C2 6.47715 6.47715 2 12 2C17.5228 2 22 6.47715 22 12C22 17.5228 17.5228 22 12 22C6.47715 22 2 17.5228 2 12ZM12 4C7.58172 4 4 7.58172 4 12C4 16.4183 7.58172 20 12 20C16.4183 20 20 16.4183 20 12C20 7.58172 16.4183 4 12 4Z" />
            </svg>
            <span>Slack</span>
            <span class="ml-2 text-[10px] bg-tymeslot-100 px-2 py-0.5 rounded-full uppercase tracking-tighter">Coming Soon</span>
          </div>
        </div>

        <!-- Tab Content -->
        <div class="space-y-12">
          <!-- Connected Webhooks Section -->
          <%= if @webhooks != [] do %>
            <div class="space-y-6">
              <div class="flex items-center justify-between">
                <.section_header
                  level={2}
                  title="Your Webhooks"
                  count={length(@webhooks)}
                />
                <button
                  phx-click="show_webhook_form"
                  phx-target={@myself}
                  class="btn-primary"
                >
                  Create Webhook
                </button>
              </div>

              <div class="grid grid-cols-1 gap-6">
                <%= for webhook <- @webhooks do %>
                  <Components.webhook_card
                    webhook={webhook}
                    testing={@testing_connection == webhook.id}
                    target={@myself}
                    on_edit={JS.push("show_edit_webhook_form", value: %{"id" => webhook.id}, target: @myself)}
                    on_delete={JS.push("show_delete_modal", value: %{"id" => webhook.id}, target: @myself)}
                    on_toggle="toggle_webhook"
                    on_test={JS.push("test_connection", value: %{"id" => webhook.id}, target: @myself)}
                    on_view_deliveries={JS.push("show_deliveries", value: %{"id" => webhook.id}, target: @myself)}
                  />
                <% end %>
              </div>
            </div>
          <% else %>
            <!-- Empty State -->
            <Components.webhook_empty_state on_create={JS.push("show_webhook_form", target: @myself)} />
          <% end %>

          <!-- Documentation Section -->
          <Components.webhook_documentation />
        </div>
      <% end %>
    </div>
    """
  end

  # Private functions

  defp with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    Flash.error(message)
    {:noreply, socket}
  end

  defp with_rate_limit(:ok, _socket, action), do: action.()

  defp do_webhook_write(params, socket, save_fn, verb) do
    metadata = AutomationHelpers.get_security_metadata(socket)

    case WebhookInputValidation.validate_webhook_form(params, metadata: metadata) do
      {:ok, sanitized} ->
        case save_fn.(sanitized) do
          {:ok, _webhook} ->
            Flash.info("Webhook #{verb} successfully")

            {:noreply,
             socket
             |> assign(:show_webhook_form, false)
             |> assign(:webhook_form_data, nil)
             |> assign(:form_errors, %{})
             |> assign(:form_values, %{})
             |> load_webhooks()}

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = AutomationHelpers.format_changeset_errors(changeset)
            Flash.error("Failed to #{verb} webhook")
            {:noreply, assign(socket, :form_errors, errors)}

          {:error, reason}
          when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, handle_feature_access_error(socket, reason)}
        end

      {:error, errors} ->
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  defp do_regenerate_token(socket) do
    case socket.assigns.selected_webhook do
      nil ->
        {:noreply, socket}

      webhook ->
        case Webhooks.regenerate_token(webhook) do
          {:ok, updated_webhook} ->
            Flash.info("Security token regenerated")

            # Update form data if we are editing this webhook
            socket =
              if socket.assigns.webhook_form_mode == :edit and
                   socket.assigns.webhook_form_data.id == updated_webhook.id do
                assign(socket, :webhook_form_data, updated_webhook)
              else
                socket
              end

            {:noreply,
             socket
             |> ModalHook.hide_modal(:regenerate_token)
             |> assign(:selected_webhook, nil)
             |> load_webhooks()}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to regenerate token")
            {:noreply, socket}
        end
    end
  end

  defp load_webhooks(socket) do
    user_id = socket.assigns.current_user.id
    webhooks = Webhooks.list_webhooks(user_id)
    assign(socket, :webhooks, webhooks)
  end

  defp get_webhook_for_user(socket, id) do
    user_id = socket.assigns.current_user.id
    webhook_id = AutomationHelpers.parse_id(id)
    Webhooks.get_webhook(webhook_id, user_id)
  end

  defp handle_feature_access_error(socket, :insufficient_plan) do
    Flash.error("Automation is available on Pro plans.")
    socket
  end

  defp handle_feature_access_error(socket, :feature_access_checker_failed) do
    Flash.error("Unable to verify subscription status. Please try again.")
    socket
  end
end
