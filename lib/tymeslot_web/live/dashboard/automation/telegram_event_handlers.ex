defmodule TymeslotWeb.Dashboard.Automation.TelegramEventHandlers do
  @moduledoc """
  Event handler implementations for Telegram management in AutomationSettingsComponent.
  Each function takes event params and a socket, returning `{:noreply, socket}`.
  Also handles PubSub-driven update callbacks for link and expiry events.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.DatabaseSchemas.TelegramIntegrationSchema
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.InputValidation, as: TelegramInputValidation
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @spec handle_show_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_form(_params, socket) do
    if Telegram.shared_bot_mode?() do
      user_id = socket.assigns.current_user.id
      Telegram.delete_pending_stubs(user_id)
      token = Telegram.generate_link_token()

      case Telegram.create_integration(user_id, %{
             name: "My Telegram",
             events: ["meeting.created"],
             link_token: token
           }) do
        {:ok, integration} ->
          deep_link = Telegram.build_deep_link(token)

          timer_ref =
            Process.send_after(
              self(),
              {:telegram_link_expired, integration.id},
              :timer.minutes(10)
            )

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
          {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

        {:error, _reason} ->
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

  @spec handle_close_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_form(_params, socket) do
    if socket.assigns.telegram_link_timer do
      Process.cancel_timer(socket.assigns.telegram_link_timer)
    end

    if socket.assigns.telegram_form_is_stub and socket.assigns.telegram_form_mode == :create do
      case socket.assigns.telegram_form_data do
        %{chat_id: nil} = integration -> Telegram.delete_integration(integration)
        _integration -> :ok
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
     |> AutomationHelpers.maybe_load_telegram()}
  end

  @spec handle_refresh_link(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_refresh_link(_params, socket) do
    if socket.assigns.telegram_link_timer do
      Process.cancel_timer(socket.assigns.telegram_link_timer)
    end

    integration = socket.assigns.telegram_form_data

    case Telegram.refresh_link_token(integration) do
      {:ok, token} ->
        deep_link = Telegram.build_deep_link(token)

        timer_ref =
          Process.send_after(self(), {:telegram_link_expired, integration.id}, :timer.minutes(10))

        {:noreply,
         socket
         |> assign(:telegram_deep_link, deep_link)
         |> assign(:telegram_link_expired, false)
         |> assign(:telegram_link_timer, timer_ref)}

      {:error, _reason} ->
        Flash.error("Failed to generate link. Please try again.")
        {:noreply, socket}
    end
  end

  @spec handle_validate_field(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_field(%{"field" => field, "value" => value}, socket) do
    form_values = Map.put(socket.assigns.telegram_form_values, field, value)
    bot_mode = if Telegram.shared_bot_mode?(), do: "shared", else: "own"
    allowed_fields = ~w(name bot_token chat_id events)
    field_atom = FormValidationHelpers.atomize_field(field, allowed_fields)

    updated_errors =
      if is_binary(value) and String.trim(value) == "" do
        FormValidationHelpers.delete_field_error(socket.assigns.telegram_form_errors, field_atom)
      else
        case TelegramInputValidation.validate_form(form_values,
               bot_mode: bot_mode,
               mode: socket.assigns.telegram_form_mode
             ) do
          {:ok, _validated} ->
            FormValidationHelpers.delete_field_error(
              socket.assigns.telegram_form_errors,
              field_atom
            )

          {:error, errs} ->
            if field_error = Map.get(errs, field_atom) do
              Map.put(socket.assigns.telegram_form_errors, field_atom, field_error)
            else
              FormValidationHelpers.delete_field_error(
                socket.assigns.telegram_form_errors,
                field_atom
              )
            end
        end
      end

    {:noreply,
     socket
     |> assign(:telegram_form_values, form_values)
     |> assign(:telegram_form_errors, updated_errors)}
  end

  def handle_validate_field(%{"field" => field} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.telegram_form_values, field, "")
    handle_validate_field(%{"field" => field, "value" => value}, socket)
  end

  @spec handle_toggle_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_event(%{"event" => event}, socket) do
    form_values = AutomationHelpers.toggle_event(socket.assigns.telegram_form_values, event)
    {:noreply, assign(socket, :telegram_form_values, form_values)}
  end

  @spec handle_create(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create(%{"telegram" => params}, socket) do
    with_telegram_write(params, :create, socket, fn bot_mode, sanitized ->
      if bot_mode == "own" do
        test_and_save_telegram(socket.assigns.current_user.id, sanitized, socket)
      else
        test_and_update_telegram(sanitized, socket)
      end
    end)
  end

  @spec handle_update(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update(%{"telegram" => params}, socket) do
    case socket.assigns.telegram_form_data do
      nil ->
        {:noreply, socket}

      integration ->
        with_telegram_write(params, :edit, socket, fn _bot_mode, sanitized ->
          case Telegram.update_integration(integration, sanitized) do
            {:ok, _updated} ->
              Flash.info("Integration updated successfully")

              {:noreply,
               socket
               |> assign(:show_telegram_form, false)
               |> assign(:telegram_form_data, nil)
               |> assign(:telegram_form_errors, %{})
               |> assign(:telegram_form_values, %{})
               |> AutomationHelpers.maybe_load_telegram()}

            {:error, %Ecto.Changeset{} = changeset} ->
              errors = AutomationHelpers.format_changeset_errors(changeset)
              Flash.error("Failed to update integration")
              {:noreply, assign(socket, :telegram_form_errors, errors)}

            {:error, reason}
            when reason in [:insufficient_plan, :feature_access_checker_failed] ->
              {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}
          end
        end)
    end
  end

  @spec handle_show_edit_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_edit_form(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
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

  @spec handle_toggle(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.toggle_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Integration status updated")
            {:noreply, AutomationHelpers.maybe_load_telegram(socket)}

          {:error, :invalid_state} ->
            Flash.error("Cannot toggle in current state")
            {:noreply, socket}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to update status")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_test(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_test(%{"id" => id}, socket) do
    AutomationHelpers.do_rate_limited_test(
      socket,
      id,
      :telegram_testing,
      &AutomationHelpers.get_telegram_for_user(&1, id),
      &Telegram.test_integration/1,
      {"Test message sent! Check Telegram.", "Integration not found"}
    )
  end

  @spec handle_reenable(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reenable(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.reenable_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Integration re-enabled")
            {:noreply, AutomationHelpers.maybe_load_telegram(socket)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error("Failed to re-enable")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_disconnect(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_disconnect(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        case Telegram.disconnect_integration(integration) do
          {:ok, _updated} ->
            Flash.info("Telegram disconnected")
            {:noreply, AutomationHelpers.maybe_load_telegram(socket)}

          {:error, :own_bot_mode} ->
            Flash.error("Cannot disconnect in own-bot mode")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_reconnect(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reconnect(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
      {:ok, integration} ->
        if socket.assigns.telegram_link_timer do
          Process.cancel_timer(socket.assigns.telegram_link_timer)
        end

        case Telegram.reconnect_integration(integration) do
          {:ok, updated, deep_link} ->
            timer_ref =
              Process.send_after(self(), {:telegram_link_expired, updated.id}, :timer.minutes(10))

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
             |> AutomationHelpers.maybe_load_telegram()}

          {:error, :own_bot_mode} ->
            Flash.error("Cannot reconnect in own-bot mode")
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error("Integration not found")
        {:noreply, socket}
    end
  end

  @spec handle_show_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_delete_modal(%{"id" => id}, socket) do
    {:noreply,
     socket
     |> ModalHook.show_modal(:telegram_delete)
     |> assign(:telegram_to_delete, AutomationHelpers.parse_id(id))}
  end

  @spec handle_hide_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_delete_modal(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:telegram_delete)
     |> assign(:telegram_to_delete, nil)}
  end

  @spec handle_delete(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete(_params, socket) do
    case socket.assigns.telegram_to_delete do
      nil ->
        {:noreply, socket}

      id ->
        case AutomationHelpers.get_telegram_for_user(socket, id) do
          {:ok, integration} ->
            case Telegram.delete_integration(integration) do
              {:ok, _deleted} ->
                Flash.info("Integration deleted")

                {:noreply,
                 socket
                 |> ModalHook.hide_modal(:telegram_delete)
                 |> assign(:telegram_to_delete, nil)
                 |> AutomationHelpers.maybe_load_telegram()}

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

  @spec handle_show_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_deliveries(%{"id" => id}, socket) do
    case AutomationHelpers.get_telegram_for_user(socket, id) do
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

  @spec handle_hide_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_deliveries(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:telegram_deliveries)
     |> assign(:selected_telegram, nil)
     |> assign(:telegram_deliveries, [])
     |> assign(:telegram_delivery_stats, nil)}
  end

  @doc """
  Handles the PubSub notification that a Telegram link was confirmed by the user.
  Advances the wizard to step 2 if the form is open for this integration.
  """
  @spec handle_linked(Phoenix.LiveView.Socket.t(), integer()) :: Phoenix.LiveView.Socket.t()
  def handle_linked(socket, integration_id) do
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
          |> AutomationHelpers.maybe_load_telegram()

        {:error, _reason} ->
          AutomationHelpers.maybe_load_telegram(socket)
      end
    else
      AutomationHelpers.maybe_load_telegram(socket)
    end
  end

  @doc """
  Handles the timer-based notification that a Telegram link has expired.
  Shows the expired state in the wizard if it is still on step 1 for this integration.
  """
  @spec handle_link_expired(Phoenix.LiveView.Socket.t(), integer()) :: Phoenix.LiveView.Socket.t()
  def handle_link_expired(socket, integration_id) do
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

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp with_telegram_write(params, mode, socket, action) do
    user_id = socket.assigns.current_user.id
    bot_mode = if Telegram.shared_bot_mode?(), do: "shared", else: "own"

    AutomationHelpers.with_rate_limit(
      RateLimiter.check_webhook_write_rate_limit(user_id),
      socket,
      fn ->
        case TelegramInputValidation.validate_form(params, bot_mode: bot_mode, mode: mode) do
          {:ok, sanitized} -> action.(bot_mode, sanitized)
          {:error, errors} -> {:noreply, assign(socket, :telegram_form_errors, errors)}
        end
      end
    )
  end

  defp test_and_save_telegram(user_id, sanitized, socket) do
    test_integration = %TelegramIntegrationSchema{
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
         |> AutomationHelpers.maybe_load_telegram()}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = AutomationHelpers.format_changeset_errors(changeset)
        Flash.error("Failed to create integration")
        {:noreply, assign(socket, :telegram_form_errors, errors)}

      {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
        {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}
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

            Flash.info("Telegram integration saved")

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
             |> AutomationHelpers.maybe_load_telegram()}

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = AutomationHelpers.format_changeset_errors(changeset)
            Flash.error("Failed to save integration")
            {:noreply, assign(socket, :telegram_form_errors, errors)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}
        end
    end
  end
end
