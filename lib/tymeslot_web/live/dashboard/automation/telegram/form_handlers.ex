defmodule TymeslotWeb.Dashboard.Automation.Telegram.FormHandlers do
  @moduledoc """
  Handles form lifecycle events for Telegram integrations: showing/closing the form,
  refreshing the link token, validating fields, and toggling events.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.InputValidation, as: TelegramInputValidation
  alias TymeslotWeb.Dashboard.Automation.Helpers, as: AutomationHelpers
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
          Flash.error(
            dgettext(
              "dashboard_automation_chat",
              "Failed to initialize integration. Please try again."
            )
          )

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
        Flash.error(
          dgettext("dashboard_automation_chat", "Failed to generate link. Please try again.")
        )

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
end
