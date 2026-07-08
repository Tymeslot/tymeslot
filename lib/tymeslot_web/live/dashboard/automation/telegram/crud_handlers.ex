defmodule TymeslotWeb.Dashboard.Automation.Telegram.CrudHandlers do
  @moduledoc """
  Handles create, update, and show-edit-form events for Telegram integrations.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.InputValidation, as: TelegramInputValidation
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Live.Shared.Flash

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
              Flash.info(
                dgettext("dashboard_automation_chat", "Integration updated successfully")
              )

              {:noreply,
               socket
               |> assign(:show_telegram_form, false)
               |> assign(:telegram_form_data, nil)
               |> assign(:telegram_form_errors, %{})
               |> assign(:telegram_form_values, %{})
               |> AutomationHelpers.maybe_load_telegram()}

            {:error, %Ecto.Changeset{} = changeset} ->
              errors = AutomationHelpers.format_changeset_errors(changeset)
              Flash.error(dgettext("dashboard_automation_chat", "Failed to update integration"))
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
        Flash.error(dgettext("dashboard_automation_chat", "Integration not found"))
        {:noreply, socket}
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
        Flash.error(
          dgettext("dashboard_automation_chat", "Test failed: %{reason}", reason: reason)
        )

        {:noreply, socket}
    end
  end

  defp save_telegram(user_id, sanitized, socket) do
    case Telegram.create_integration(user_id, sanitized) do
      {:ok, _integration} ->
        Flash.info(dgettext("dashboard_automation_chat", "Telegram integration created"))

        {:noreply,
         socket
         |> assign(:show_telegram_form, false)
         |> assign(:telegram_form_data, nil)
         |> assign(:telegram_form_errors, %{})
         |> assign(:telegram_form_values, %{})
         |> AutomationHelpers.maybe_load_telegram()}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = AutomationHelpers.format_changeset_errors(changeset)
        Flash.error(dgettext("dashboard_automation_chat", "Failed to create integration"))
        {:noreply, assign(socket, :telegram_form_errors, errors)}

      {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
        {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}
    end
  end

  defp test_and_update_telegram(sanitized, socket) do
    case socket.assigns.telegram_form_data do
      nil ->
        Flash.error(
          dgettext("dashboard_automation_chat", "Integration not found. Please try again.")
        )

        {:noreply, socket}

      integration ->
        case Telegram.update_integration(integration, sanitized) do
          {:ok, _updated} ->
            if socket.assigns.telegram_link_timer do
              Process.cancel_timer(socket.assigns.telegram_link_timer)
            end

            Flash.info(dgettext("dashboard_automation_chat", "Telegram integration saved"))

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
            Flash.error(dgettext("dashboard_automation_chat", "Failed to save integration"))
            {:noreply, assign(socket, :telegram_form_errors, errors)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}
        end
    end
  end
end
