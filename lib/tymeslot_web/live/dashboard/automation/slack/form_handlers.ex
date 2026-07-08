defmodule TymeslotWeb.Dashboard.Automation.Slack.FormHandlers do
  @moduledoc """
  Handles form lifecycle events for Slack integrations: opening the webhook URL
  form, closing the form, validating fields, and toggling events.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Slack
  alias Tymeslot.Slack.InputValidation, as: SlackInputValidation
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Opens the form in `:webhook_url` mode. Triggered by the "Use webhook URL"
  button on the empty state and the secondary CTA elsewhere.
  """
  @spec handle_show_webhook_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_webhook_form(_params, socket) do
    {:noreply,
     open_slack_form(socket, :webhook_url, nil, %{
       "name" => "",
       "events" => Slack.default_events_for_new_integration(),
       "webhook_url" => "",
       "webhook_channel_hint" => ""
     })}
  end

  @doc """
  Opens the channel picker for a `:pending_oauth` integration. Used by the
  query-param deep link from the OAuth callback redirect and by the "Pick a
  channel" button on the integration card.
  """
  @spec handle_show_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_form(%{"id" => id}, socket) do
    case AutomationHelpers.get_slack_for_user(socket, id) do
      {:ok, integration} ->
        {:noreply, open_oauth_form(socket, integration)}

      {:error, _reason} ->
        Flash.error(dgettext("dashboard_automation_chat", "Slack integration not found"))
        {:noreply, socket}
    end
  end

  def handle_show_form(_params, socket), do: {:noreply, socket}

  @spec handle_close_form(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_form(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_slack_form, false)
     |> assign(:slack_form_data, nil)
     |> assign(:slack_form_errors, %{})
     |> assign(:slack_form_values, %{})
     |> AutomationHelpers.maybe_load_slack()}
  end

  @spec handle_validate(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate(%{"slack" => params}, socket) do
    # Sync DOM values into the socket but do not surface errors here. Per-field
    # blur validation (`handle_validate_field/2`) decides when to display errors
    # so the form does not light up red while the user is still typing.
    form_values = Map.merge(socket.assigns.slack_form_values, params)
    {:noreply, assign(socket, :slack_form_values, form_values)}
  end

  def handle_validate(_params, socket), do: {:noreply, socket}

  @spec handle_validate_field(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_field(%{"field" => field, "value" => value}, socket) do
    form_values = Map.put(socket.assigns.slack_form_values, field, value)
    mode = socket.assigns.slack_form_mode
    allowed_fields = ~w(name webhook_url webhook_channel_hint channel_id)
    field_atom = FormValidationHelpers.atomize_field(field, allowed_fields)

    updated_errors =
      if is_binary(value) and String.trim(value) == "" do
        FormValidationHelpers.delete_field_error(socket.assigns.slack_form_errors, field_atom)
      else
        case SlackInputValidation.validate_form(form_values, mode: mode) do
          {:ok, _sanitized} ->
            FormValidationHelpers.delete_field_error(
              socket.assigns.slack_form_errors,
              field_atom
            )

          {:error, errs} ->
            if field_error = Map.get(errs, field_atom) do
              Map.put(socket.assigns.slack_form_errors, field_atom, field_error)
            else
              FormValidationHelpers.delete_field_error(
                socket.assigns.slack_form_errors,
                field_atom
              )
            end
        end
      end

    {:noreply,
     socket
     |> assign(:slack_form_values, form_values)
     |> assign(:slack_form_errors, updated_errors)}
  end

  def handle_validate_field(%{"field" => field} = params, socket) do
    value = params["value"] || Map.get(socket.assigns.slack_form_values, field, "")
    handle_validate_field(%{"field" => field, "value" => value}, socket)
  end

  @spec handle_toggle_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_event(%{"event" => event}, socket) do
    form_values = AutomationHelpers.toggle_event(socket.assigns.slack_form_values, event)
    {:noreply, assign(socket, :slack_form_values, form_values)}
  end

  # ============================================================================
  # Helpers shared with CrudHandlers
  # ============================================================================

  @doc """
  Opens the form pre-filled for a `:pending_oauth` integration (channel picker).
  """
  @spec open_oauth_form(Phoenix.LiveView.Socket.t(), term()) :: Phoenix.LiveView.Socket.t()
  def open_oauth_form(socket, integration) do
    open_slack_form(socket, :oauth_pending, integration, %{
      "name" => integration.name || "",
      "events" => integration.events || Slack.default_events_for_new_integration(),
      "channel_id" => "",
      "channel_name" => ""
    })
  end

  defp open_slack_form(socket, mode, data, values) do
    socket
    |> assign(:show_slack_form, true)
    |> assign(:slack_form_mode, mode)
    |> assign(:slack_form_data, data)
    |> assign(:slack_form_timestamp, System.system_time())
    |> assign(:slack_form_errors, %{})
    |> assign(:slack_form_values, values)
  end
end
