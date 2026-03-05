defmodule TymeslotWeb.Dashboard.AutomationSettingsComponent do
  @moduledoc """
  LiveComponent for managing automation in the dashboard.
  Supports webhooks and Telegram integrations.
  """
  use TymeslotWeb, :live_component

  require Logger

  alias Phoenix.LiveView.JS
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.InputValidation, as: TelegramInputValidation
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.InputValidation, as: WebhookInputValidation
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Dashboard.Automation.Modals
  alias TymeslotWeb.Dashboard.Automation.TelegramCard
  alias TymeslotWeb.Dashboard.Automation.TelegramEmptyState
  alias TymeslotWeb.Dashboard.Automation.TelegramFormComponent
  alias TymeslotWeb.Dashboard.Automation.WebhookCard
  alias TymeslotWeb.Dashboard.Automation.WebhookDocumentation
  alias TymeslotWeb.Dashboard.Automation.WebhookEmptyState
  alias TymeslotWeb.Dashboard.Automation.WebhookFormComponent
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  @spec mount(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(socket) do
    modal_configs = [
      {:delete, false},
      {:deliveries, false},
      {:regenerate_token, false},
      {:telegram_delete, false},
      {:telegram_deliveries, false}
    ]

    telegram_enabled = Telegram.telegram_enabled?()

    {:ok,
     socket
     |> ModalHook.mount_modal(modal_configs)
     # Tab state
     |> assign(:active_tab, :webhooks)
     |> assign(:telegram_enabled, telegram_enabled)
     # Webhook state
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
     |> assign(:webhook_form_timestamp, nil)
     # Telegram state
     |> assign(:telegram_integrations, [])
     |> assign(:telegram_form_errors, %{})
     |> assign(:telegram_form_values, %{})
     |> assign(:telegram_saving, false)
     |> assign(:telegram_testing, nil)
     |> assign(:telegram_to_delete, nil)
     |> assign(:selected_telegram, nil)
     |> assign(:telegram_deliveries, [])
     |> assign(:telegram_delivery_stats, nil)
     |> assign(:show_telegram_form, false)
     |> assign(:telegram_form_mode, :create)
     |> assign(:telegram_form_data, nil)
     |> assign(:telegram_form_timestamp, nil)
     |> assign(:telegram_wizard_step, 1)
     |> assign(:telegram_link_expired, false)
     |> assign(:telegram_link_timer, nil)
     |> assign(:telegram_deep_link, nil)
     |> assign(:telegram_form_is_stub, false)}
  end

  @impl Phoenix.LiveComponent
  @spec update(map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def update(%{telegram_linked_integration_id: integration_id}, socket) do
    {:ok, handle_telegram_linked(socket, integration_id)}
  end

  def update(%{telegram_link_expired_id: integration_id}, socket) do
    {:ok, handle_telegram_link_expired(socket, integration_id)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> load_webhooks()
      |> maybe_load_telegram()
      |> maybe_subscribe_telegram()

    {:ok, socket}
  end

  # ============================================================================
  # Tab Switching
  # ============================================================================

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  # ============================================================================
  # Webhook Events (unchanged)
  # ============================================================================

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

  # ============================================================================
  # Telegram Events
  # ============================================================================

  def handle_event("show_telegram_form", _params, socket) do
    if Telegram.shared_bot_mode?() do
      user_id = socket.assigns.current_user.id

      case Telegram.create_integration(user_id, %{name: "My Telegram", events: ["meeting.created"]}) do
        {:ok, integration} ->
          token = Telegram.generate_link_token(user_id, integration.id)
          deep_link = Telegram.build_deep_link(token)
          timer_ref = Process.send_after(self(), {:telegram_link_expired, integration.id}, :timer.minutes(10))

          {:noreply,
           socket
           |> assign(:show_telegram_form, true)
           |> assign(:telegram_form_mode, :create)
           |> assign(:telegram_form_data, integration)
           |> assign(:telegram_form_timestamp, System.system_time())
           |> assign(:telegram_form_errors, %{})
           |> assign(:telegram_form_values, %{"name" => "", "events" => []})
           |> assign(:telegram_wizard_step, 1)
           |> assign(:telegram_link_expired, false)
           |> assign(:telegram_deep_link, deep_link)
           |> assign(:telegram_link_timer, timer_ref)
           |> assign(:telegram_form_is_stub, true)}

        {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
          {:noreply, handle_feature_access_error(socket, reason)}

        {:error, _} ->
          Flash.error("Failed to initialize integration. Please try again.")
          {:noreply, socket}
      end
    else
      {:noreply,
       socket
       |> assign(:show_telegram_form, true)
       |> assign(:telegram_form_mode, :create)
       |> assign(:telegram_form_data, nil)
       |> assign(:telegram_form_timestamp, System.system_time())
       |> assign(:telegram_form_errors, %{})
       |> assign(:telegram_form_values, %{"name" => "", "events" => []})
       |> assign(:telegram_wizard_step, 1)
       |> assign(:telegram_link_expired, false)
       |> assign(:telegram_deep_link, nil)}
    end
  end

  def handle_event("close_telegram_form", _params, socket) do
    if socket.assigns.telegram_link_timer do
      Process.cancel_timer(socket.assigns.telegram_link_timer)
    end

    # Only delete stub integrations (pending_link with no chat_id) when the wizard is abandoned
    if socket.assigns.telegram_form_is_stub and socket.assigns.telegram_form_mode == :create do
      case socket.assigns.telegram_form_data do
        %{chat_id: nil} = integration -> Telegram.delete_integration(integration)
        _ -> :ok
      end
    end

    {:noreply,
     socket
     |> assign(:show_telegram_form, false)
     |> assign(:telegram_form_data, nil)
     |> assign(:telegram_form_errors, %{})
     |> assign(:telegram_form_values, %{})
     |> assign(:telegram_link_timer, nil)
     |> assign(:telegram_deep_link, nil)
     |> assign(:telegram_link_expired, false)
     |> assign(:telegram_form_is_stub, false)
     |> maybe_load_telegram()}
  end

  def handle_event("refresh_telegram_link", _params, socket) do
    if socket.assigns.telegram_link_timer do
      Process.cancel_timer(socket.assigns.telegram_link_timer)
    end

    integration = socket.assigns.telegram_form_data
    user_id = socket.assigns.current_user.id
    token = Telegram.generate_link_token(user_id, integration.id)
    deep_link = Telegram.build_deep_link(token)
    timer_ref = Process.send_after(self(), {:telegram_link_expired, integration.id}, :timer.minutes(10))

    {:noreply,
     socket
     |> assign(:telegram_deep_link, deep_link)
     |> assign(:telegram_link_expired, false)
     |> assign(:telegram_link_timer, timer_ref)}
  end

  def handle_event("validate_telegram_field", %{"field" => field, "value" => value}, socket) do
    form_values = Map.put(socket.assigns.telegram_form_values, field, value)
    bot_mode = if Telegram.shared_bot_mode?(), do: "shared", else: "own"

    errors =
      if is_binary(value) and String.trim(value) == "" do
        fields = ~w(name bot_token chat_id events)
        atom_field = FormValidationHelpers.atomize_field(field, fields)
        FormValidationHelpers.delete_field_error(socket.assigns.telegram_form_errors, atom_field)
      else
        case TelegramInputValidation.validate_form(form_values,
               bot_mode: bot_mode,
               mode: socket.assigns.telegram_form_mode
             ) do
          {:ok, _validated} -> %{}
          {:error, errs} -> errs
        end
      end

    {:noreply,
     socket
     |> assign(:telegram_form_values, form_values)
     |> assign(:telegram_form_errors, errors)}
  end

  def handle_event("validate_telegram_field", %{"field" => field} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.telegram_form_values, field, "")
    handle_event("validate_telegram_field", %{"field" => field, "value" => value}, socket)
  end

  def handle_event("toggle_telegram_event", %{"event" => event}, socket) do
    form_values = AutomationHelpers.toggle_event(socket.assigns.telegram_form_values, event)
    {:noreply, assign(socket, :telegram_form_values, form_values)}
  end

  def handle_event("create_telegram", %{"telegram" => params}, socket) do
    user_id = socket.assigns.current_user.id
    bot_mode = if Telegram.shared_bot_mode?(), do: "shared", else: "own"

    with_rate_limit(RateLimiter.check_webhook_write_rate_limit(user_id), socket, fn ->
      case TelegramInputValidation.validate_form(params, bot_mode: bot_mode) do
        {:ok, sanitized} ->
          if bot_mode == "own" do
            test_and_save_telegram(user_id, sanitized, socket)
          else
            # Shared bot mode: integration already exists, update it with configured name/events
            test_and_update_telegram(sanitized, socket)
          end

        {:error, errors} ->
          {:noreply, assign(socket, :telegram_form_errors, errors)}
      end
    end)
  end

  def handle_event("update_telegram", %{"telegram" => params}, socket) do
    case socket.assigns.telegram_form_data do
      nil ->
        {:noreply, socket}

      integration ->
        user_id = socket.assigns.current_user.id
        bot_mode = if Telegram.shared_bot_mode?(), do: "shared", else: "own"

        with_rate_limit(RateLimiter.check_webhook_write_rate_limit(user_id), socket, fn ->
          case TelegramInputValidation.validate_form(params, bot_mode: bot_mode, mode: :edit) do
            {:ok, sanitized} ->
              case Telegram.update_integration(integration, sanitized) do
                {:ok, _updated} ->
                  Flash.info("Integration updated successfully")

                  {:noreply,
                   socket
                   |> assign(:show_telegram_form, false)
                   |> assign(:telegram_form_data, nil)
                   |> assign(:telegram_form_errors, %{})
                   |> assign(:telegram_form_values, %{})
                   |> maybe_load_telegram()}

                {:error, %Ecto.Changeset{} = changeset} ->
                  errors = AutomationHelpers.format_changeset_errors(changeset)
                  Flash.error("Failed to update integration")
                  {:noreply, assign(socket, :telegram_form_errors, errors)}

                {:error, reason}
                when reason in [:insufficient_plan, :feature_access_checker_failed] ->
                  {:noreply, handle_feature_access_error(socket, reason)}
              end

            {:error, errors} ->
              {:noreply, assign(socket, :telegram_form_errors, errors)}
          end
        end)
    end
  end

  def handle_event("show_edit_telegram_form", %{"id" => id}, socket) do
    case get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        {:noreply,
         socket
         |> assign(:show_telegram_form, true)
         |> assign(:telegram_form_mode, :edit)
         |> assign(:telegram_form_data, integration)
         |> assign(:telegram_form_timestamp, System.system_time())
         |> assign(:telegram_form_errors, %{})
         |> assign(:telegram_form_values, %{
           "name" => integration.name,
           "events" => integration.events,
           "chat_id" => if(integration.bot_mode == "own", do: integration.chat_id || "", else: "")
         })}

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_telegram", %{"id" => id}, socket) do
    case get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.toggle_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Integration status updated")
            {:noreply, maybe_load_telegram(socket)}

          {:error, :invalid_state} ->
            Flash.error("Cannot toggle in current state")
            {:noreply, socket}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to update status")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("test_telegram", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_webhook_test_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        integration_id = AutomationHelpers.parse_id(id)
        socket = assign(socket, :telegram_testing, integration_id)

        case get_telegram_for_user(socket, id) do
          {:ok, integration} ->
            case Telegram.test_integration(integration) do
              :ok ->
                Flash.info("Test message sent! Check Telegram.")
                {:noreply, assign(socket, :telegram_testing, nil)}

              {:error, reason} ->
                Flash.error("Test failed: #{reason}")
                {:noreply, assign(socket, :telegram_testing, nil)}
            end

          {:error, _reason} ->
            Flash.error("Integration not found")
            {:noreply, assign(socket, :telegram_testing, nil)}
        end
    end
  end

  def handle_event("reenable_telegram", %{"id" => id}, socket) do
    case get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.reenable_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Integration re-enabled")
            {:noreply, maybe_load_telegram(socket)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to re-enable")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("disconnect_telegram", %{"id" => id}, socket) do
    case get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.disconnect_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Telegram disconnected")
            {:noreply, maybe_load_telegram(socket)}

          {:error, :own_bot_mode} ->
            Flash.error("Cannot disconnect in own-bot mode")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("reconnect_telegram", %{"id" => id}, socket) do
    case get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        if socket.assigns.telegram_link_timer do
          Process.cancel_timer(socket.assigns.telegram_link_timer)
        end

        case Telegram.reconnect_integration(integration) do
          {:ok, updated, deep_link} ->
            timer_ref = Process.send_after(self(), {:telegram_link_expired, updated.id}, :timer.minutes(10))

            {:noreply,
             socket
             |> assign(:show_telegram_form, true)
             |> assign(:telegram_form_mode, :create)
             |> assign(:telegram_form_data, updated)
             |> assign(:telegram_form_timestamp, System.system_time())
             |> assign(:telegram_form_errors, %{})
             |> assign(:telegram_form_values, %{
               "name" => integration.name,
               "events" => integration.events
             })
             |> assign(:telegram_wizard_step, 1)
             |> assign(:telegram_link_expired, false)
             |> assign(:telegram_deep_link, deep_link)
             |> assign(:telegram_link_timer, timer_ref)
             |> assign(:telegram_form_is_stub, false)
             |> maybe_load_telegram()}

          {:error, :own_bot_mode} ->
            Flash.error("Cannot reconnect in own-bot mode")
            {:noreply, socket}
        end

      {:error, _} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("show_telegram_delete_modal", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> ModalHook.show_modal(:telegram_delete)
     |> assign(:telegram_to_delete, AutomationHelpers.parse_id(id))}
  end

  def handle_event("hide_telegram_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:telegram_delete)
     |> assign(:telegram_to_delete, nil)}
  end

  def handle_event("delete_telegram", _params, socket) do
    case socket.assigns.telegram_to_delete do
      nil ->
        {:noreply, socket}

      id ->
        case get_telegram_for_user(socket, id) do
          {:ok, integration} ->
            case Telegram.delete_integration(integration) do
              {:ok, _deleted} ->
                Flash.info("Integration deleted")

                {:noreply,
                 socket
                 |> ModalHook.hide_modal(:telegram_delete)
                 |> assign(:telegram_to_delete, nil)
                 |> maybe_load_telegram()}

              {:error, _reason} ->
                Flash.error("Failed to delete")
                {:noreply, socket}
            end

          {:error, _reason} ->
            Flash.error("Integration not found")
            {:noreply, socket}
        end
    end
  end

  def handle_event("show_telegram_deliveries", %{"id" => id}, socket) do
    case get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        deliveries = Telegram.list_deliveries(integration.id, limit: 50)
        stats = Telegram.get_delivery_stats(integration.id, days: 7)

        {:noreply,
         socket
         |> ModalHook.show_modal(:telegram_deliveries)
         |> assign(:selected_telegram, integration)
         |> assign(:telegram_deliveries, deliveries)
         |> assign(:telegram_delivery_stats, stats)}

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  def handle_event("hide_telegram_deliveries", _params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:telegram_deliveries)
     |> assign(:selected_telegram, nil)
     |> assign(:telegram_deliveries, [])
     |> assign(:telegram_delivery_stats, nil)}
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <!-- Webhook Modals -->
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

      <!-- Telegram Delete Modal -->
      <Modals.delete_webhook_modal
        show={@show_telegram_delete_modal}
        on_cancel={JS.push("hide_telegram_delete_modal", target: @myself)}
        on_confirm={JS.push("delete_telegram", target: @myself)}
      />

      <!-- Telegram Deliveries Modal -->
      <%= if @show_telegram_deliveries_modal && @selected_telegram do %>
        <.telegram_deliveries_modal
          show={@show_telegram_deliveries_modal}
          integration={@selected_telegram}
          deliveries={@telegram_deliveries}
          stats={@telegram_delivery_stats}
          on_close={JS.push("hide_telegram_deliveries", target: @myself)}
        />
      <% end %>

      <%= cond do %>
        <% @show_webhook_form -> %>
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
        <% @show_telegram_form -> %>
        <div class="animate-in fade-in slide-in-from-bottom-4 duration-500">
          <.live_component
            module={TelegramFormComponent}
            id={"telegram-form-#{@telegram_form_mode}-#{@telegram_form_timestamp}"}
            mode={@telegram_form_mode}
            integration={@telegram_form_data}
            form_values={@telegram_form_values}
            form_errors={@telegram_form_errors}
            saving={@telegram_saving}
            current_user={@current_user}
            parent_component={@myself}
            wizard_step={@telegram_wizard_step}
            link_expired={@telegram_link_expired}
            deep_link={@telegram_deep_link}
          />
        </div>
        <% true -> %>
        <.section_header icon={:webhook} title="Automation" />

        <!-- Tabs Navigation -->
        <div class="flex flex-wrap gap-4 bg-tymeslot-50/50 p-2 rounded-[2rem] border-2 border-tymeslot-50 mb-10">
          <button
            phx-click={JS.push("switch_tab", value: %{"tab" => "webhooks"}, target: @myself)}
            class={tab_class(@active_tab == :webhooks)}
          >
            <IconComponents.icon name={:webhook} class="w-5 h-5" />
            <span>Webhooks</span>
          </button>

          <%= if @telegram_enabled do %>
            <button
              phx-click={JS.push("switch_tab", value: %{"tab" => "telegram"}, target: @myself)}
              class={tab_class(@active_tab == :telegram)}
            >
              <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
                <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
              </svg>
              <span>Telegram</span>
            </button>
          <% else %>
            <div class="flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 opacity-60 cursor-not-allowed">
              <svg class="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
                <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
              </svg>
              <span>Telegram</span>
              <span class="ml-2 text-[10px] bg-tymeslot-100 px-2 py-0.5 rounded-full uppercase tracking-tighter">Disabled</span>
            </div>
          <% end %>
        </div>

        <!-- Tab Content -->
        <div class="space-y-12">
          <%= if @active_tab == :webhooks do %>
            <.webhook_tab_content
              webhooks={@webhooks}
              testing_connection={@testing_connection}
              myself={@myself}
            />
          <% else %>
            <.telegram_tab_content
              integrations={@telegram_integrations}
              telegram_testing={@telegram_testing}
              myself={@myself}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp webhook_tab_content(assigns) do
    ~H"""
    <%= if @webhooks != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header level={2} title="Your Webhooks" count={length(@webhooks)} />
          <button phx-click="show_webhook_form" phx-target={@myself} class="btn-primary">
            Create Webhook
          </button>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for webhook <- @webhooks do %>
            <WebhookCard.webhook_card
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
      <WebhookEmptyState.webhook_empty_state on_create={JS.push("show_webhook_form", target: @myself)} />
    <% end %>

    <WebhookDocumentation.webhook_documentation />
    """
  end

  defp telegram_tab_content(assigns) do
    ~H"""
    <%= if @integrations != [] do %>
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <.section_header level={2} title="Your Telegram Integrations" count={length(@integrations)} />
          <button phx-click="show_telegram_form" phx-target={@myself} class="btn-primary">
            Add Telegram Account
          </button>
        </div>

        <div class="grid grid-cols-1 gap-6">
          <%= for integration <- @integrations do %>
            <TelegramCard.telegram_card
              integration={integration}
              testing={@telegram_testing == integration.id}
              target={@myself}
              on_edit={JS.push("show_edit_telegram_form", value: %{"id" => integration.id}, target: @myself)}
              on_delete={JS.push("show_telegram_delete_modal", value: %{"id" => integration.id}, target: @myself)}
              on_toggle="toggle_telegram"
              on_test={JS.push("test_telegram", value: %{"id" => integration.id}, target: @myself)}
              on_view_deliveries={JS.push("show_telegram_deliveries", value: %{"id" => integration.id}, target: @myself)}
              on_reenable={JS.push("reenable_telegram", value: %{"id" => integration.id}, target: @myself)}
              on_disconnect={JS.push("disconnect_telegram", value: %{"id" => integration.id}, target: @myself)}
              on_reconnect={
                if integration.bot_mode == "shared" do
                  JS.push("reconnect_telegram", value: %{"id" => integration.id}, target: @myself)
                end
              }
            />
          <% end %>
        </div>
      </div>
    <% else %>
      <TelegramEmptyState.telegram_empty_state on_create={JS.push("show_telegram_form", target: @myself)} />
    <% end %>
    """
  end

  defp telegram_deliveries_modal(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      phx-click={@on_close}
    >
      <div
        class="bg-white rounded-2xl shadow-2xl w-full max-w-2xl max-h-[80vh] overflow-hidden"
        phx-click-away={@on_close}
      >
        <div class="p-6 border-b border-slate-100">
          <div class="flex items-center justify-between">
            <h3 class="text-token-xl font-black text-tymeslot-900">
              Delivery History — <%= @integration.name %>
            </h3>
            <button phx-click={@on_close} class="text-slate-400 hover:text-slate-600">
              <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <%= if @stats do %>
            <div class="flex gap-6 mt-4 text-token-sm">
              <div>
                <span class="text-slate-500">Last 7 days:</span>
                <span class="font-bold text-slate-900"><%= @stats.total %> deliveries</span>
              </div>
              <div>
                <span class="text-green-600 font-bold"><%= @stats.successful %> sent</span>
              </div>
              <div>
                <span class="text-red-600 font-bold"><%= @stats.failed %> failed</span>
              </div>
            </div>
          <% end %>
        </div>

        <div class="overflow-y-auto max-h-[60vh] p-6">
          <%= if @deliveries == [] do %>
            <p class="text-center text-slate-400 py-8">No delivery history yet.</p>
          <% else %>
            <div class="space-y-3">
              <%= for delivery <- @deliveries do %>
                <div class="p-3 rounded-token-xl border border-slate-100 text-token-sm">
                  <div class="flex items-center justify-between mb-1">
                    <span class="font-bold text-slate-700"><%= delivery.event_type %></span>
                    <span class={[
                      "font-bold",
                      if(delivery.response_status && delivery.response_status >= 200 && delivery.response_status < 300,
                        do: "text-green-600",
                        else: "text-red-600"
                      )
                    ]}>
                      <%= if delivery.response_status do %>
                        HTTP <%= delivery.response_status %>
                      <% else %>
                        Error
                      <% end %>
                    </span>
                  </div>
                  <div class="text-slate-400">
                    <%= if delivery.inserted_at do %>
                      <%= Calendar.strftime(delivery.inserted_at, "%B %d, %Y at %I:%M %p") %>
                    <% end %>
                  </div>
                  <%= if delivery.error_message do %>
                    <div class="mt-1 text-red-500 text-xs"><%= delivery.error_message %></div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp tab_class(true) do
    "flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-white border-white text-turquoise-600 shadow-xl shadow-tymeslot-200/50 scale-[1.02] cursor-default"
  end

  defp tab_class(false) do
    "flex-1 flex items-center justify-center gap-3 px-6 py-4 rounded-token-2xl text-token-sm font-black uppercase tracking-widest transition-all duration-300 border-2 bg-transparent border-transparent text-tymeslot-400 hover:text-tymeslot-600 hover:bg-white/50 cursor-pointer"
  end

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

  defp test_and_save_telegram(user_id, sanitized, socket) do
    # Build a temporary integration struct for testing
    test_integration = %Tymeslot.DatabaseSchemas.TelegramIntegrationSchema{
      bot_mode: "own",
      bot_token: sanitized[:bot_token],
      chat_id: sanitized[:chat_id]
    }

    case Telegram.test_integration(test_integration) do
      :ok ->
        save_telegram(user_id, sanitized, socket)

      {:error, reason} ->
        Flash.error("Test failed: #{reason}")
        {:noreply, socket}
    end
  end

  defp save_telegram(user_id, sanitized, socket) do
    case Telegram.create_integration(user_id, sanitized) do
      {:ok, _integration} ->
        Flash.info("Telegram integration created")

        {:noreply,
         socket
         |> assign(:show_telegram_form, false)
         |> assign(:telegram_form_data, nil)
         |> assign(:telegram_form_errors, %{})
         |> assign(:telegram_form_values, %{})
         |> maybe_load_telegram()}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = AutomationHelpers.format_changeset_errors(changeset)
        Flash.error("Failed to create integration")
        {:noreply, assign(socket, :telegram_form_errors, errors)}

      {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
        {:noreply, handle_feature_access_error(socket, reason)}
    end
  end

  defp test_and_update_telegram(sanitized, socket) do
    case socket.assigns.telegram_form_data do
      nil ->
        Flash.error("Integration not found. Please try again.")
        {:noreply, socket}

      integration ->
        case Telegram.update_integration(integration, sanitized) do
          {:ok, _updated} ->
            if socket.assigns.telegram_link_timer do
              Process.cancel_timer(socket.assigns.telegram_link_timer)
            end

            Flash.info("Telegram integration created")

            {:noreply,
             socket
             |> assign(:show_telegram_form, false)
             |> assign(:telegram_form_data, nil)
             |> assign(:telegram_form_errors, %{})
             |> assign(:telegram_form_values, %{})
             |> assign(:telegram_link_timer, nil)
             |> assign(:telegram_deep_link, nil)
             |> assign(:telegram_link_expired, false)
             |> assign(:telegram_form_is_stub, false)
             |> maybe_load_telegram()}

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = AutomationHelpers.format_changeset_errors(changeset)
            Flash.error("Failed to create integration")
            {:noreply, assign(socket, :telegram_form_errors, errors)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, handle_feature_access_error(socket, reason)}
        end
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

            socket =
              if socket.assigns.webhook_form_mode == :edit and
                   socket.assigns.webhook_form_data &&
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

  defp maybe_load_telegram(socket) do
    if socket.assigns.telegram_enabled do
      user_id = socket.assigns.current_user.id
      integrations = Telegram.list_integrations(user_id)
      assign(socket, :telegram_integrations, integrations)
    else
      socket
    end
  end

  defp maybe_subscribe_telegram(socket) do
    if socket.assigns.telegram_enabled and connected?(socket) do
      user_id = socket.assigns.current_user.id
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "telegram_link:#{user_id}")
    end

    socket
  end

  defp get_webhook_for_user(socket, id) do
    user_id = socket.assigns.current_user.id
    webhook_id = AutomationHelpers.parse_id(id)
    Webhooks.get_webhook(webhook_id, user_id)
  end

  defp get_telegram_for_user(socket, id) do
    user_id = socket.assigns.current_user.id
    integration_id = AutomationHelpers.parse_id(id)
    Telegram.get_integration(integration_id, user_id)
  end

  defp handle_feature_access_error(socket, :insufficient_plan) do
    Flash.error("Automation is available on Pro plans.")
    socket
  end

  defp handle_feature_access_error(socket, :feature_access_checker_failed) do
    Flash.error("Unable to verify subscription status. Please try again.")
    socket
  end

  defp handle_telegram_linked(socket, integration_id) do
    if socket.assigns.telegram_link_timer do
      Process.cancel_timer(socket.assigns.telegram_link_timer)
    end

    socket = assign(socket, :telegram_link_timer, nil)

    if socket.assigns.show_telegram_form &&
         socket.assigns.telegram_form_data &&
         socket.assigns.telegram_form_data.id == integration_id do
      user_id = socket.assigns.current_user.id

      case Telegram.get_integration(integration_id, user_id) do
        {:ok, updated_integration} ->
          socket
          |> assign(:telegram_form_data, updated_integration)
          |> assign(:telegram_wizard_step, 2)
          |> maybe_load_telegram()

        {:error, _} ->
          maybe_load_telegram(socket)
      end
    else
      maybe_load_telegram(socket)
    end
  end

  defp handle_telegram_link_expired(socket, integration_id) do
    socket = assign(socket, :telegram_link_timer, nil)

    if socket.assigns.show_telegram_form &&
         socket.assigns.telegram_form_data &&
         socket.assigns.telegram_form_data.id == integration_id &&
         socket.assigns.telegram_wizard_step == 1 do
      assign(socket, :telegram_link_expired, true)
    else
      socket
    end
  end
end
