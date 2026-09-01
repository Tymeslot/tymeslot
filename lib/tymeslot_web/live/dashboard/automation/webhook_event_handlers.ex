defmodule TymeslotWeb.Dashboard.Automation.WebhookEventHandlers do
  @moduledoc """
  Event handler implementations for webhook management in AutomationSettingsComponent.
  Each function takes event params and a socket, returning `{:noreply, socket}`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.InputValidation, as: WebhookInputValidation
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @spec handle_show_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_form(_params, socket) do
    {:noreply, open_webhook_form(socket, :create, nil)}
  end

  @spec handle_close_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_form(_params, socket) do
    {:noreply, close_webhook_form(socket)}
  end

  @spec handle_validate_field(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_field(%{"field" => field, "value" => value}, socket) do
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

  def handle_validate_field(%{"field" => field} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.form_values, field, "")
    handle_validate_field(%{"field" => field, "value" => value}, socket)
  end

  @spec handle_toggle_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_event(%{"event" => event}, socket) do
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

  @spec handle_create(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_create(%{"webhook" => params}, socket) do
    user_id = socket.assigns.current_user.id

    AutomationHelpers.with_rate_limit(
      RateLimiter.check_webhook_write_rate_limit(user_id),
      socket,
      fn ->
        do_webhook_write(params, socket, &Webhooks.create_webhook(user_id, &1), "created")
      end
    )
  end

  @spec handle_show_edit_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_edit_form(%{"id" => id}, socket) do
    case AutomationHelpers.get_webhook_for_user(socket, id) do
      {:ok, webhook} ->
        {:noreply, open_webhook_form(socket, :edit, webhook)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation", "Webhook not found"))
        {:noreply, socket}
    end
  end

  @spec handle_update(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update(%{"webhook" => params}, socket) do
    case socket.assigns.webhook_form_data do
      nil ->
        {:noreply, socket}

      webhook ->
        user_id = socket.assigns.current_user.id

        AutomationHelpers.with_rate_limit(
          RateLimiter.check_webhook_write_rate_limit(user_id),
          socket,
          fn ->
            do_webhook_write(params, socket, &Webhooks.update_webhook(webhook, &1), "updated")
          end
        )
    end
  end

  @spec handle_show_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_delete_modal(%{"id" => id}, socket) do
    {:noreply,
     socket
     |> ModalHook.show_modal(:delete)
     |> assign(:webhook_to_delete, AutomationHelpers.parse_id(id))}
  end

  @spec handle_hide_delete_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_delete_modal(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:delete)
     |> assign(:webhook_to_delete, nil)}
  end

  @spec handle_delete(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete(_params, socket) do
    case socket.assigns.webhook_to_delete do
      nil ->
        {:noreply, socket}

      id ->
        case AutomationHelpers.get_webhook_for_user(socket, id) do
          {:ok, webhook} ->
            case Webhooks.delete_webhook(webhook) do
              {:ok, _result} ->
                Flash.info(dgettext("dashboard_automation", "Webhook deleted successfully"))

                {:noreply,
                 socket
                 |> ModalHook.hide_modal(:delete)
                 |> assign(:webhook_to_delete, nil)
                 |> AutomationHelpers.load_webhooks()}

              {:error, _reason} ->
                Flash.error(dgettext("dashboard_automation", "Failed to delete webhook"))
                {:noreply, socket}
            end

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_automation", "Webhook not found"))
            {:noreply, socket}
        end
    end
  end

  @spec handle_toggle(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle(%{"id" => id}, socket) do
    case AutomationHelpers.get_webhook_for_user(socket, id) do
      {:ok, webhook} ->
        case Webhooks.toggle_webhook(webhook) do
          {:ok, _result} ->
            Flash.info(dgettext("dashboard_automation", "Webhook status updated"))
            {:noreply, AutomationHelpers.load_webhooks(socket)}

          {:error, reason}
          when reason in [
                 :insufficient_plan,
                 :feature_disabled,
                 :pro_required,
                 :stripe_required,
                 :feature_access_checker_failed
               ] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_automation", "Failed to update webhook status"))
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation", "Webhook not found"))
        {:noreply, socket}
    end
  end

  @spec handle_test_connection(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_test_connection(%{"id" => id}, socket) do
    AutomationHelpers.do_rate_limited_test(
      socket,
      id,
      :testing_connection,
      &AutomationHelpers.get_webhook_for_user(&1, id),
      &Webhooks.test_webhook_connection(&1.url, &1.webhook_token),
      {dgettext("dashboard_automation", "Webhook test successful! Check your endpoint."),
       dgettext("dashboard_automation", "Webhook not found")}
    )
  end

  @spec handle_show_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_deliveries(%{"id" => id}, socket) do
    case AutomationHelpers.get_webhook_for_user(socket, id) do
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
        Flash.error(dgettext("dashboard_automation", "Webhook not found"))
        {:noreply, socket}
    end
  end

  @spec handle_show_regenerate_token_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_regenerate_token_modal(%{"id" => id}, socket) do
    case AutomationHelpers.get_webhook_for_user(socket, id) do
      {:ok, webhook} ->
        {:noreply,
         socket
         |> ModalHook.show_modal(:regenerate_token)
         |> assign(:selected_webhook, webhook)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation", "Webhook not found"))
        {:noreply, socket}
    end
  end

  @spec handle_hide_regenerate_token_modal(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_regenerate_token_modal(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:regenerate_token)
     |> assign(:selected_webhook, nil)}
  end

  @spec handle_regenerate_token(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_regenerate_token(_params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_webhook_token_regen_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        do_regenerate_token(socket)
    end
  end

  @spec handle_hide_deliveries(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_deliveries(_params, socket) do
    {:noreply,
     socket
     |> ModalHook.hide_modal(:deliveries)
     |> assign(:selected_webhook, nil)
     |> assign(:deliveries, [])
     |> assign(:delivery_stats, nil)}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp do_webhook_write(params, socket, save_fn, verb) do
    metadata = AutomationHelpers.get_security_metadata(socket)

    case WebhookInputValidation.validate_webhook_form(params, metadata: metadata) do
      {:ok, sanitized} ->
        case save_fn.(sanitized) do
          {:ok, _webhook} ->
            Flash.info(webhook_write_success_message(verb))
            {:noreply, socket |> close_webhook_form() |> AutomationHelpers.load_webhooks()}

          {:error, %Ecto.Changeset{} = changeset} ->
            errors = AutomationHelpers.format_changeset_errors(changeset)
            Flash.error(webhook_write_failure_message(verb))
            {:noreply, assign(socket, :form_errors, errors)}

          {:error, reason}
          when reason in [
                 :insufficient_plan,
                 :feature_disabled,
                 :pro_required,
                 :stripe_required,
                 :feature_access_checker_failed
               ] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          # `save_fn` is `Webhooks.create_webhook/2` or `update_webhook/2`,
          # whose specs only promise a changeset or one of the access-error
          # atoms above — but a case with no catch-all turns any drift from
          # that contract into a `CaseClauseError` instead of a flash.
          {:error, _other_reason} ->
            Flash.error(webhook_write_failure_message(verb))
            {:noreply, socket}
        end

      # A throttled save previously assigned `%{form: ...}`, which the modal
      # does not render, so the save silently did nothing.
      {:error, :rate_limited} ->
        Flash.error(dgettext("dashboard_automation", "Too many requests. Please slow down."))

        {:noreply, socket}

      {:error, errors} ->
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  defp webhook_write_success_message("created"),
    do: dgettext("dashboard_automation", "Webhook created successfully")

  defp webhook_write_success_message("updated"),
    do: dgettext("dashboard_automation", "Webhook updated successfully")

  defp webhook_write_failure_message("created"),
    do: dgettext("dashboard_automation", "Failed to create webhook")

  defp webhook_write_failure_message("updated"),
    do: dgettext("dashboard_automation", "Failed to update webhook")

  defp do_regenerate_token(socket) do
    case socket.assigns.selected_webhook do
      nil ->
        {:noreply, socket}

      webhook ->
        case Webhooks.regenerate_token(webhook) do
          {:ok, updated_webhook} ->
            Flash.info(dgettext("dashboard_automation", "Security token regenerated"))

            {:noreply,
             socket
             |> maybe_refresh_form_data(updated_webhook)
             |> ModalHook.hide_modal(:regenerate_token)
             |> assign(:selected_webhook, nil)
             |> AutomationHelpers.load_webhooks()}

          {:error, reason}
          when reason in [
                 :insufficient_plan,
                 :feature_disabled,
                 :pro_required,
                 :stripe_required,
                 :feature_access_checker_failed
               ] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_automation", "Failed to regenerate token"))
            {:noreply, socket}
        end
    end
  end

  defp open_webhook_form(socket, :create, nil) do
    socket
    |> assign(:show_webhook_form, true)
    |> assign(:webhook_form_mode, :create)
    |> assign(:webhook_form_data, nil)
    |> assign(:webhook_form_timestamp, System.system_time())
    |> assign(:form_errors, %{})
    |> assign(:form_values, %{"name" => "", "url" => "", "events" => []})
  end

  defp open_webhook_form(socket, :edit, webhook) do
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
    })
  end

  defp close_webhook_form(socket) do
    socket
    |> assign(:show_webhook_form, false)
    |> assign(:webhook_form_data, nil)
    |> assign(:form_errors, %{})
    |> assign(:form_values, %{})
  end

  defp maybe_refresh_form_data(
         %{assigns: %{webhook_form_mode: :edit, webhook_form_data: %{id: form_id}}} = socket,
         %{id: form_id} = updated_webhook
       ) do
    assign(socket, :webhook_form_data, updated_webhook)
  end

  defp maybe_refresh_form_data(socket, _updated_webhook), do: socket
end
