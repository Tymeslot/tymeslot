defmodule TymeslotWeb.Dashboard.Automation.Slack.StateHandlers do
  @moduledoc """
  Handles state-transition events for Slack integrations: toggling, testing,
  disconnecting, reconnecting, and re-enabling.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Slack
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Live.Shared.Flash

  @spec handle_toggle_active(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_active(%{"id" => id}, socket) do
    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, integration} ->
        case Slack.toggle_integration(integration) do
          {:ok, _updated} ->
            Flash.info(dgettext("dashboard_automation_chat", "Integration status updated"))
            {:noreply, AutomationHelpers.maybe_load_slack(socket)}

          {:error, :invalid_state} ->
            Flash.error(dgettext("dashboard_automation_chat", "Cannot toggle in current state"))
            {:noreply, socket}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_automation_chat", "Failed to update status"))
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}
    end
  end

  @spec handle_test(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_test(%{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_webhook_test_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        run_test(id, socket)
    end
  end

  defp run_test(id, socket) do
    entity_id = AutomationHelpers.parse_id(id)
    socket = assign(socket, :slack_testing, entity_id)

    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, integration} ->
        case Slack.test_integration(integration) do
          :ok ->
            Flash.info(dgettext("dashboard_automation_chat", "Test message sent! Check Slack."))
            {:noreply, assign(socket, :slack_testing, nil)}

          {:error, reason} ->
            Flash.error(Slack.translate_error(reason))
            {:noreply, assign(socket, :slack_testing, nil)}
        end

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, assign(socket, :slack_testing, nil)}
    end
  end

  @doc """
  Disconnects an OAuth-mode integration by clearing its channel and demoting
  it back to `:pending_oauth`. Webhook URL integrations have no separate
  "disconnect" state — they are deleted instead.
  """
  @spec handle_disconnect(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_disconnect(%{"id" => id}, socket) do
    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, %{app_mode: "oauth"} = integration} ->
        case Slack.disconnect(integration) do
          {:ok, _updated} ->
            Flash.info(
              dgettext(
                "dashboard_automation_chat",
                "Slack channel disconnected. Pick a new channel to reconnect."
              )
            )

            {:noreply, AutomationHelpers.maybe_load_slack(socket)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_automation_chat", "Failed to disconnect Slack"))
            {:noreply, socket}
        end

      {:ok, _other} ->
        Flash.error(dgettext("dashboard_automation_chat", "Cannot disconnect this integration"))
        {:noreply, socket}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}
    end
  end

  @doc """
  Restarts the OAuth install flow from scratch by redirecting the browser to
  the OAuth start controller endpoint. The controller redirects on to Slack,
  so we need a full-page navigation rather than a LiveView patch.
  """
  @spec handle_reconnect(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reconnect(_params, socket) do
    {:noreply, LiveView.redirect(socket, to: "/api/slack/oauth/start")}
  end

  @spec handle_reenable(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reenable(%{"id" => id}, socket) do
    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, integration} ->
        case Slack.reenable_integration(integration) do
          {:ok, _updated} ->
            Flash.info(dgettext("dashboard_automation_chat", "Slack integration re-enabled"))
            {:noreply, AutomationHelpers.maybe_load_slack(socket)}

          {:error, reason} when reason in [:insufficient_plan, :feature_access_checker_failed] ->
            {:noreply, AutomationHelpers.handle_feature_access_error(socket, reason)}

          {:error, _reason} ->
            Flash.error(dgettext("dashboard_automation_chat", "Failed to re-enable"))
            {:noreply, socket}
        end

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}
    end
  end
end
