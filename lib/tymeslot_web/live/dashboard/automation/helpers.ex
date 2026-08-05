defmodule TymeslotWeb.Dashboard.Automation.Helpers do
  @moduledoc """
  Helper functions for the AutomationSettingsComponent.
  Contains business logic, state management, and utility functions.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  require Logger

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Slack
  alias Tymeslot.Telegram
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias Tymeslot.Utils.FormHelpers
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.InputValidation, as: WebhookInputValidation
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.Flash

  @doc """
  Toggles an event in the list of selected events.
  """
  @spec toggle_event(map(), String.t()) :: map()
  def toggle_event(form_values, event) do
    current_events = Map.get(form_values, "events", [])

    new_events =
      if event in current_events do
        List.delete(current_events, event)
      else
        [event | current_events]
      end

    Map.put(form_values, "events", new_events)
  end

  @doc """
  Validates a single field and returns updated errors map.
  """
  @spec validate_field(map(), map(), String.t(), any(), map()) :: map()
  def validate_field(form_values, current_errors, field, value, metadata) do
    allowed_fields = ["name", "url", "events"]

    if field in allowed_fields do
      updated_values = Map.put(form_values, field, value)

      case WebhookInputValidation.validate_webhook_form(updated_values, metadata: metadata) do
        {:ok, _sanitized} ->
          field_atom = String.to_existing_atom(field)
          Map.delete(current_errors, field_atom)

        {:error, errors} ->
          field_atom = String.to_existing_atom(field)
          field_error = Map.get(errors, field_atom)

          if field_error do
            Map.put(current_errors, field_atom, field_error)
          else
            Map.delete(current_errors, field_atom)
          end
      end
    else
      current_errors
    end
  end

  @doc """
  Parses an ID from string or integer.
  """
  @spec parse_id(integer() | String.t()) :: integer()
  def parse_id(id) when is_integer(id), do: id

  def parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _value} -> int
      _other -> 0
    end
  end

  @doc """
  Formats changeset errors into a flat map.
  """
  @spec format_changeset_errors(Ecto.Changeset.t()) :: map()
  def format_changeset_errors(changeset) do
    FormHelpers.format_changeset_errors(changeset)
    |> Enum.map(fn {k, v} -> {k, List.first(v)} end)
    |> Map.new()
  end

  @doc """
  Gets security metadata from socket.
  """
  @spec get_security_metadata(Phoenix.LiveView.Socket.t()) :: map()
  def get_security_metadata(socket) do
    DashboardHelpers.get_security_metadata(socket)
  end

  @doc """
  Returns true if the named field has a non-empty trimmed string value.
  """
  @spec field_present?(map(), String.t()) :: boolean()
  def field_present?(values, key) do
    String.trim(Map.get(values, key, "")) != ""
  end

  @doc """
  Returns true if at least one event is selected.
  """
  @spec any_events_selected?(map()) :: boolean()
  def any_events_selected?(values) do
    Enum.any?(Map.get(values, "events", []))
  end

  @doc """
  Loads the current user's webhooks into the socket.
  """
  @spec load_webhooks(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load_webhooks(socket) do
    user_id = socket.assigns.current_user.id
    webhooks = Webhooks.list_webhooks(user_id)
    assign(socket, :webhooks, webhooks)
  end

  @doc """
  Loads Telegram integrations into the socket if Telegram is enabled.
  """
  @spec maybe_load_telegram(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_load_telegram(socket) do
    if socket.assigns.telegram_enabled do
      user_id = socket.assigns.current_user.id
      integrations = Telegram.list_integrations(user_id)
      assign(socket, :telegram_integrations, integrations)
    else
      socket
    end
  end

  @doc """
  Loads Slack integrations into the socket if Slack is enabled.
  """
  @spec maybe_load_slack(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_load_slack(socket) do
    if Map.get(socket.assigns, :slack_enabled, false) do
      user_id = socket.assigns.current_user.id
      integrations = Slack.list_integrations(user_id)
      assign(socket, :slack_integrations, integrations)
    else
      socket
    end
  end

  @doc """
  Looks up a Slack integration by ID, scoped to the current user.
  """
  @spec get_slack_for_user(Phoenix.LiveView.Socket.t(), integer() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_slack_for_user(socket, id) do
    user_id = socket.assigns.current_user.id
    integration_id = parse_id(id)
    Slack.get_integration(integration_id, user_id)
  end

  @doc """
  Formats a DateTime for display in the automation UI, or "Never" for nil.

  The date stays locale-ordered while the clock follows the organiser's
  resolved preference: these timestamps are read only by the organiser, so they
  should match the clock the rest of their dashboard uses.
  """
  @spec format_datetime(DateTime.t() | nil, String.t()) :: String.t()
  def format_datetime(datetime, time_format)

  def format_datetime(nil, _time_format), do: dgettext("dashboard_automation", "Never")

  def format_datetime(%DateTime{} = dt, time_format) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    date = LocaleFormat.format_date(dt, locale)
    time = TimeFormat.format(dt, time_format)
    dgettext("dashboard_automation", "%{date} at %{time}", date: date, time: time)
  end

  @doc """
  Looks up a webhook by ID, scoped to the current user.
  """
  @spec get_webhook_for_user(Phoenix.LiveView.Socket.t(), integer() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_webhook_for_user(socket, id) do
    user_id = socket.assigns.current_user.id
    webhook_id = parse_id(id)
    Webhooks.get_webhook(webhook_id, user_id)
  end

  @doc """
  Looks up a Telegram integration by ID, scoped to the current user.
  """
  @spec get_telegram_for_user(Phoenix.LiveView.Socket.t(), integer() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_telegram_for_user(socket, id) do
    user_id = socket.assigns.current_user.id
    integration_id = parse_id(id)
    Telegram.get_integration(integration_id, user_id)
  end

  @doc """
  Sends the appropriate flash message for a feature access error and returns the socket unchanged.
  """
  @spec handle_feature_access_error(Phoenix.LiveView.Socket.t(), atom()) ::
          Phoenix.LiveView.Socket.t()
  def handle_feature_access_error(socket, :insufficient_plan) do
    Flash.error(dgettext("dashboard_automation", "Automation is available on Pro plans."))
    socket
  end

  def handle_feature_access_error(socket, reason)
      when reason in [:pro_required, :feature_disabled] do
    Flash.error(
      dgettext("dashboard_automation", "This automation feature is available on the Pro plan.")
    )

    socket
  end

  def handle_feature_access_error(socket, :stripe_required) do
    Flash.error(
      dgettext("dashboard_automation", "Connect a Stripe account to use this automation.")
    )

    socket
  end

  def handle_feature_access_error(socket, :feature_access_checker_failed) do
    Flash.error(
      dgettext("dashboard_automation", "Unable to verify subscription status. Please try again.")
    )

    socket
  end

  def handle_feature_access_error(socket, other) do
    Logger.warning("handle_feature_access_error: unhandled reason", reason: inspect(other))

    Flash.error(
      dgettext("dashboard_automation", "Unable to perform this action. Please try again.")
    )

    socket
  end

  @doc """
  Executes `action` if the rate limit check passes; otherwise sends an error flash
  and returns `{:noreply, socket}`.
  """
  @spec with_rate_limit(
          :ok | {:error, :rate_limited, String.t()},
          Phoenix.LiveView.Socket.t(),
          (-> {:noreply, Phoenix.LiveView.Socket.t()})
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    Flash.error(message)
    {:noreply, socket}
  end

  def with_rate_limit(:ok, _socket, action), do: action.()

  @doc """
  Runs a rate-limited test action: checks the rate limit, sets a loading key,
  fetches the entity, calls test_fn, and clears the loading key on completion.
  `get_fn` receives the socket and returns `{:ok, entity} | {:error, reason}`.
  `test_fn` receives the entity and returns `:ok | {:error, reason}`.
  """
  @spec do_rate_limited_test(
          Phoenix.LiveView.Socket.t(),
          integer() | String.t(),
          atom(),
          (Phoenix.LiveView.Socket.t() -> {:ok, term()} | {:error, term()}),
          (term() -> :ok | {:error, term()}),
          {String.t(), String.t()}
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def do_rate_limited_test(socket, id, testing_key, get_fn, test_fn, {success_msg, not_found_msg}) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_webhook_test_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        entity_id = parse_id(id)
        socket = assign(socket, testing_key, entity_id)

        case get_fn.(socket) do
          {:ok, entity} ->
            case test_fn.(entity) do
              :ok ->
                Flash.info(success_msg)
                {:noreply, assign(socket, testing_key, nil)}

              {:error, reason} ->
                Flash.error(
                  dgettext("dashboard_automation", "Test failed: %{reason}", reason: reason)
                )

                {:noreply, assign(socket, testing_key, nil)}
            end

          {:error, _reason} ->
            Flash.error(not_found_msg)
            {:noreply, assign(socket, testing_key, nil)}
        end
    end
  end
end
