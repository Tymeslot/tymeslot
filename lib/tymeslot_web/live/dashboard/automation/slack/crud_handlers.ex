defmodule TymeslotWeb.Dashboard.Automation.Slack.CrudHandlers do
  @moduledoc """
  Handles create, update, show-edit-form, and show-channel-picker events for
  Slack integrations.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Slack
  alias Tymeslot.Slack.InputValidation, as: SlackInputValidation
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Dashboard.Automation.Slack.FormHandlers
  alias TymeslotWeb.Live.Shared.Flash

  @spec handle_save_webhook(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_save_webhook(%{"slack" => params}, socket) do
    user_id = socket.assigns.current_user.id

    AutomationHelpers.with_rate_limit(
      RateLimiter.check_webhook_write_rate_limit(user_id),
      socket,
      fn ->
        case SlackInputValidation.validate_form(params, mode: :webhook_url) do
          {:ok, sanitized} ->
            attrs =
              sanitized
              |> Map.put(:app_mode, "webhook_url")
              |> Map.put(:is_active, true)

            persist_create(user_id, attrs, socket)

          {:error, errors} ->
            {:noreply, assign(socket, :slack_form_errors, errors)}
        end
      end
    )
  end

  @spec handle_save_channel(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_save_channel(%{"slack" => params}, socket) do
    case socket.assigns.slack_form_data do
      nil ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}

      integration ->
        case SlackInputValidation.validate_form(params, mode: :oauth_pending) do
          {:ok, sanitized} ->
            case Slack.set_channel(integration, sanitized) do
              {:ok, _updated} ->
                Flash.info(dgettext("dashboard_automation_chat", "Slack channel saved"))

                {:noreply,
                 socket
                 |> close_form()
                 |> AutomationHelpers.maybe_load_slack()}

              {:error, %Ecto.Changeset{} = changeset} ->
                errors = AutomationHelpers.format_changeset_errors(changeset)
                Flash.error(dgettext("dashboard_automation_chat", "Failed to save channel"))
                {:noreply, assign(socket, :slack_form_errors, errors)}

              {:error, reason}
              when reason in [:insufficient_plan, :feature_access_checker_failed] ->
                {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}
            end

          {:error, errors} ->
            {:noreply, assign(socket, :slack_form_errors, errors)}
        end
    end
  end

  @spec handle_update(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update(%{"slack" => params}, socket) do
    case socket.assigns.slack_form_data do
      nil ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}

      integration ->
        mode = socket.assigns.slack_form_mode

        case SlackInputValidation.validate_form(params, mode: mode) do
          {:ok, sanitized} ->
            case Slack.update_integration(integration, sanitized) do
              {:ok, _updated} ->
                Flash.info(dgettext("dashboard_automation_chat", "Slack integration updated"))

                {:noreply,
                 socket
                 |> close_form()
                 |> AutomationHelpers.maybe_load_slack()}

              {:error, %Ecto.Changeset{} = changeset} ->
                errors = AutomationHelpers.format_changeset_errors(changeset)
                Flash.error(dgettext("dashboard_automation_chat", "Failed to update integration"))
                {:noreply, assign(socket, :slack_form_errors, errors)}

              {:error, reason}
              when reason in [:insufficient_plan, :feature_access_checker_failed] ->
                {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}
            end

          {:error, errors} ->
            {:noreply, assign(socket, :slack_form_errors, errors)}
        end
    end
  end

  @spec handle_show_edit_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_edit_form(%{"id" => id}, socket) do
    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, integration} ->
        mode = edit_mode_for(integration)

        {:noreply,
         socket
         |> assign(:show_slack_form, true)
         |> assign(:slack_form_mode, mode)
         |> assign(:slack_form_data, integration)
         |> assign(:slack_form_timestamp, System.system_time())
         |> assign(:slack_form_errors, %{})
         |> assign(:slack_form_values, edit_form_values(integration, mode))}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}
    end
  end

  @spec handle_show_channel_picker(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_channel_picker(%{"id" => id}, socket) do
    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, integration} ->
        {:noreply, FormHandlers.open_oauth_form(socket, integration)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp persist_create(user_id, attrs, socket) do
    case Slack.create_integration(user_id, attrs) do
      {:ok, _integration} ->
        Flash.info(dgettext("dashboard_automation_chat", "Slack integration created"))

        {:noreply,
         socket
         |> close_form()
         |> AutomationHelpers.maybe_load_slack()}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = AutomationHelpers.format_changeset_errors(changeset)
        Flash.error(dgettext("dashboard_automation_chat", "Failed to create integration"))
        {:noreply, assign(socket, :slack_form_errors, errors)}

      {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
        {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

      {:error, :feature_disabled} ->
        Flash.error(
          dgettext(
            "dashboard_automation_chat",
            "Slack notifications are not enabled on this deployment."
          )
        )

        {:noreply, socket}
    end
  end

  defp close_form(socket) do
    socket
    |> assign(:show_slack_form, false)
    |> assign(:slack_form_data, nil)
    |> assign(:slack_form_errors, %{})
    |> assign(:slack_form_values, %{})
  end

  defp edit_mode_for(%{app_mode: "oauth"}), do: :oauth_existing
  defp edit_mode_for(%{app_mode: "webhook_url"}), do: :webhook_url_existing
  defp edit_mode_for(_other), do: :webhook_url_existing

  defp edit_form_values(integration, :oauth_existing) do
    %{
      "name" => integration.name,
      "events" => integration.events,
      "channel_id" => integration.channel_id || "",
      "channel_name" => integration.channel_name || ""
    }
  end

  # Never round-trip the stored webhook URL into the form — that would render
  # the decrypted secret as a value in the DOM and LiveView diffs. Leave the
  # field blank; the validator treats a blank field as "keep current".
  defp edit_form_values(integration, :webhook_url_existing) do
    %{
      "name" => integration.name,
      "events" => integration.events,
      "webhook_url" => "",
      "webhook_channel_hint" => integration.webhook_channel_hint || ""
    }
  end
end
