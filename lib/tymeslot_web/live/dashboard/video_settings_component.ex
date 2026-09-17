defmodule TymeslotWeb.Dashboard.VideoSettingsComponent do
  @moduledoc """
  LiveComponent for managing video integrations in the dashboard.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.InputValidation, as: VideoInputValidation
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils
  alias TymeslotWeb.Dashboard.VideoSettings.ComponentView
  alias TymeslotWeb.Dashboard.VideoSettings.FormInput
  alias TymeslotWeb.Helpers.IntegrationProviders
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:integrations, [])
     |> assign(:config_provider, nil)
     |> assign(:selected_provider, nil)
     |> assign(:form_errors, %{})
     |> assign(:form_values, %{})
     |> assign(:saving, false)
     |> assign(:testing_connection, nil)
     |> assign(:health_states, %{})
     |> assign(:show_picker, false)
     |> assign(:nextcloud_calendars, [])
     |> assign(:copied_nextcloud_login, nil)
     |> assign(:available_video_providers, Directory.list(:video))}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> maybe_load_integrations(assigns)

    {:ok, socket}
  end

  # The integrations hub already loads the video list and health states for
  # its active tab child (one query per hub render instead of two) and
  # passes them down as the `integrations`/`health_states` props. Reuse them
  # when present; fall back to loading independently otherwise — e.g. when
  # mounted standalone via the `:video_integration` dashboard action, or when
  # a `send_update/2` targets us with a partial assign (those always want a
  # fresh reload, matching prior behaviour).
  defp maybe_load_integrations(socket, %{
         integrations: _integrations,
         health_states: _health_states
       }),
       do: socket

  defp maybe_load_integrations(socket, _assigns), do: load_integrations(socket)

  @impl Phoenix.LiveComponent
  def handle_event("show_picker", _params, socket) do
    {:noreply, assign(socket, :show_picker, true)}
  end

  def handle_event("hide_picker", _params, socket) do
    {:noreply,
     assign(socket, show_picker: false, config_provider: nil, copied_nextcloud_login: nil)}
  end

  def handle_event("track_form_change", %{"integration" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  # Only the server and login name enter the socket. The app password stays in
  # the calendar integration and is read again when the form is submitted.
  def handle_event("copy_nextcloud_login", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with integration_id when is_integer(integration_id) <- FormInput.integration_id(id),
         {:ok, login} <- Calendar.nextcloud_login(integration_id, user_id) do
      form_values =
        Map.merge(socket.assigns.form_values || %{}, %{
          "base_url" => login.server_url,
          "client_id" => login.username
        })

      {:noreply,
       assign(socket,
         form_values: form_values,
         form_errors: %{},
         copied_nextcloud_login: %{
           id: integration_id,
           server_url: login.server_url,
           username: login.username
         }
       )}
    else
      _unavailable ->
        {:noreply, copied_login_unavailable(socket)}
    end
  end

  def handle_event("back_to_providers", _params, socket) do
    {:noreply,
     assign(socket,
       config_provider: nil,
       form_errors: %{},
       form_values: %{},
       copied_nextcloud_login: nil
     )}
  end

  def handle_event("setup_provider", %{"provider" => provider}, socket) do
    case ProviderConfig.parse(provider) do
      {:ok, provider_atom} when provider_atom != :none ->
        if Directory.oauth?(:video, provider_atom) == true do
          initiate_oauth(socket, provider_atom)
        else
          {:noreply,
           assign(socket,
             config_provider: provider,
             show_picker: true,
             form_errors: %{},
             form_values: %{},
             nextcloud_calendars: nextcloud_calendars(socket, provider_atom),
             copied_nextcloud_login: nil
           )}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("provider_changed", %{"value" => provider}, socket) do
    {:noreply,
     assign(socket, config_provider: provider, form_errors: %{}, copied_nextcloud_login: nil)}
  end

  def handle_event("validate_field", %{"field" => field} = params, socket) do
    value = Map.get(params, "value", Map.get(socket.assigns.form_values || %{}, field, ""))

    form_values =
      (socket.assigns.form_values || %{})
      |> Map.put(field, value)
      |> Map.put("provider", socket.assigns.config_provider)

    form_errors =
      FormInput.validate_field(
        socket.assigns.form_errors || %{},
        field,
        value,
        DashboardHelpers.get_security_metadata(socket)
      )

    {:noreply, assign(socket, form_values: form_values, form_errors: form_errors)}
  end

  def handle_event("add_integration", %{"integration" => submitted}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      socket = assign(socket, :saving, true)

      case with_copied_app_password(submitted, socket.assigns.copied_nextcloud_login, user_id) do
        {:ok, params} ->
          create_from_form(socket, submitted, params)

        {:error, :copied_login_unavailable} ->
          {:noreply,
           socket |> copied_login_unavailable() |> assign(form_values: submitted, saving: false)}
      end
    end)
  end

  def handle_event("reconnect_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      case FormInput.integration_id(id) do
        nil ->
          {:noreply, socket}

        integration_id ->
          case Video.get_integration(user_id, integration_id) do
            {:ok, integration} ->
              case Video.oauth_reconnect_url(user_id, integration) do
                {:ok, url} ->
                  {:noreply, redirect(socket, external: url)}

                {:error, _reason} ->
                  notify_parent(
                    {:flash,
                     {:error,
                      dgettext("dashboard_integrations", "Failed to reconnect. Please try again.")}}
                  )

                  {:noreply, socket}
              end

            {:error, :not_found} ->
              {:noreply, socket}
          end
      end
    end)
  end

  def handle_event("toggle_integration", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_integration_write_rate_limit(user_id), socket, fn ->
      case FormInput.integration_id(id) do
        nil ->
          {:noreply, socket}

        integration_id ->
          case Video.toggle_integration(user_id, integration_id) do
            {:ok, _result} ->
              notify_parent(
                {:flash,
                 {:info, dgettext("dashboard_integrations", "Integration status updated")}}
              )

              notify_parent({:integration_updated, :video})
              {:noreply, load_integrations(socket)}

            {:error, :duplicate_account} ->
              notify_parent(
                {:flash,
                 {:error,
                  dgettext(
                    "dashboard_integrations",
                    "Cannot reactivate - another active integration already uses this account"
                  )}}
              )

              {:noreply, socket}

            {:error, _reason} ->
              notify_parent(
                {:flash,
                 {:error,
                  dgettext("dashboard_integrations", "Failed to update integration status")}}
              )

              {:noreply, socket}
          end
      end
    end)
  end

  def handle_event("test_connection", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    # `Video.test_connection/2` routes through `ConnectionProbe`, the single
    # choke point for connection-test rate limiting: every provider, OAuth
    # included, now draws from a real bucket, so no compensating guard
    # belongs here.
    case FormInput.integration_id(id) do
      nil ->
        {:noreply, socket}

      int_id ->
        provider = get_provider_name(socket, int_id)

        socket =
          socket
          |> assign(:testing_connection, int_id)
          |> start_async(:test_connection, fn ->
            {provider, Video.test_connection(user_id, int_id)}
          end)

        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_async(:test_connection, {:ok, {provider, result}}, socket) do
    case result do
      {:ok, message} ->
        notify_parent(
          {:flash, {:info, IntegrationProviders.format_test_success_message(provider, message)}}
        )

      {:error, {:rate_limited, _message} = refusal} ->
        notify_parent(
          {:flash, {:error, IntegrationProviders.connection_test_refusal_message(refusal)}}
        )

      {:error, :unattributable} ->
        notify_parent(
          {:flash,
           {:error, IntegrationProviders.connection_test_refusal_message(:unattributable)}}
        )

      # Covers both a bare message and a provider's tagged `{tag, message}`;
      # the tag drives field mapping, never the copy shown here.
      {:error, reason} ->
        notify_parent(
          {:flash, {:error, IntegrationProviders.connection_test_error_message(reason)}}
        )
    end

    {:noreply, assign(socket, :testing_connection, nil)}
  end

  def handle_async(:test_connection, {:exit, reason}, socket) do
    notify_parent(
      {:flash,
       {:error,
        dgettext("dashboard_integrations", "Connection test failed unexpectedly: %{reason}",
          reason: inspect(reason)
        )}}
    )

    {:noreply, assign(socket, :testing_connection, nil)}
  end

  def handle_async({:connection_advisory, _integration_id}, result, socket) do
    if warning = connection_advisory_warning(result) do
      notify_parent({:flash, {:warning, warning}})
    end

    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns), do: ComponentView.settings(assigns)

  # Private functions

  defp handle_create_result({:ok, integration}, _provider, socket) do
    notify_parent({:integration_added, :video})

    {:noreply,
     socket
     |> reset_form_state()
     |> assign(:show_picker, false)
     |> load_integrations()
     |> assign(:form_values, %{})
     |> announce_added(integration)}
  end

  defp handle_create_result({:error, %Ecto.Changeset{} = changeset}, _provider, socket) do
    {:noreply,
     socket
     |> assign(:form_errors, %{base: ChangesetUtils.get_first_error(changeset)})
     |> assign(:saving, false)}
  end

  # A provider with a single fixed host (kMeet) allows one active integration.
  defp handle_create_result({:error, :provider_already_connected}, _provider, socket) do
    {:noreply,
     socket
     |> assign(:form_errors, %{
       base:
         dgettext(
           "dashboard_integrations",
           "This provider is already connected. Deactivate or remove the existing integration before adding another."
         )
     })
     |> assign(:saving, false)}
  end

  # A Jitsi integration is keyed on its server URL, so the duplicate is that
  # server, active or not.
  defp handle_create_result({:error, :duplicate_integration}, "jitsi", socket) do
    {:noreply,
     socket
     |> assign(:form_errors, %{
       base:
         dgettext(
           "dashboard_integrations",
           "This server is already connected. Edit or remove the existing integration instead."
         )
     })
     |> assign(:saving, false)}
  end

  # A Nextcloud Talk integration is keyed on its server and login name, so the
  # duplicate is that account, active or not.
  defp handle_create_result({:error, :duplicate_integration}, "nextcloud_talk", socket) do
    {:noreply,
     socket
     |> assign(:form_errors, %{
       base:
         dgettext(
           "dashboard_integrations",
           "This Nextcloud account is already connected. Edit or remove the existing integration instead."
         )
     })
     |> assign(:saving, false)}
  end

  # The Jitsi and Nextcloud Talk providers' own validation words its messages
  # for the organiser, and they concern the credentials as often as the URL, so
  # they are shown for the whole form rather than under the URL field.
  defp handle_create_result({:error, message}, provider, socket)
       when provider in ["jitsi", "nextcloud_talk"] and is_binary(message) do
    {:noreply,
     socket
     |> assign(:form_errors, %{base: message})
     |> assign(:saving, false)}
  end

  defp handle_create_result({:error, :duplicate_integration}, _provider, socket) do
    {:noreply,
     socket
     |> assign(:form_errors, %{
       base:
         dgettext(
           "dashboard_integrations",
           "A video integration with this configuration already exists"
         )
     })
     |> assign(:saving, false)}
  end

  defp handle_create_result({:error, reason}, _provider, socket) do
    {:noreply,
     socket
     |> assign(:saving, false)
     |> assign(:form_errors, IntegrationProviders.reason_to_form_errors(reason))}
  end

  # The confirmation goes out at once, so it survives this component going
  # away before a probe finishes.
  defp announce_added(socket, integration) do
    notify_parent(
      {:flash,
       {:info, dgettext("dashboard_integrations", "Video integration added successfully")}}
    )

    maybe_probe_connection(socket, integration)
  end

  # Advisory only. A Jitsi root path may legitimately answer with a redirect,
  # a 403 or an authentication wall, and a server that is briefly unreachable
  # is still worth keeping configured, so the probe can only add a warning,
  # never change the outcome of the save. It runs after the form has closed,
  # so a slow server never holds the dialog open, and each save gets its own
  # task name: a second `start_async/3` under the same name would drop the
  # first save's result.
  defp maybe_probe_connection(socket, %{provider: "jitsi"} = integration) do
    start_async(socket, {:connection_advisory, integration.id}, fn ->
      Video.probe_integration(integration, scope: :interactive)
    end)
  end

  defp maybe_probe_connection(socket, _integration), do: socket

  defp connection_advisory_warning({:ok, {:ok, _message}}), do: nil

  # A refused probe never reached the server, so it says nothing about it.
  defp connection_advisory_warning({:ok, {:error, {:rate_limited, _message}}}), do: nil
  defp connection_advisory_warning({:ok, {:error, :unattributable}}), do: nil

  defp connection_advisory_warning(_failed) do
    dgettext(
      "dashboard_integrations",
      "Saved, but the server did not answer as expected. Check the URL, or use Test connection once it is reachable."
    )
  end

  # `submitted` is what the browser sent; `params` may also carry an app
  # password read from a copied calendar connection, so only `submitted` is ever
  # kept in the socket.
  defp create_from_form(socket, submitted, params) do
    user_id = socket.assigns.current_user.id
    metadata = DashboardHelpers.get_security_metadata(socket)

    case VideoInputValidation.validate_video_integration_form(params, metadata: metadata) do
      # The validated map is the whole set of fields the provider's form
      # accepts, so anything else the browser sent never reaches the context.
      {:ok, sanitized_params} ->
        provider = params["provider"] || socket.assigns.config_provider

        if is_nil(provider) do
          {:noreply,
           socket
           |> assign(:form_errors, %{
             base: dgettext("dashboard_integrations", "Please select a provider")
           })
           |> assign(:saving, false)}
        else
          handle_create_result(
            Video.create_integration(
              user_id,
              provider,
              FormInput.to_atom_keys(sanitized_params)
            ),
            provider,
            socket
          )
        end

      {:error, validation_errors} ->
        {:noreply,
         socket
         |> assign(:form_errors, validation_errors)
         |> assign(:form_values, submitted)
         |> assign(:saving, false)}
    end
  end

  defp copied_login_unavailable(socket) do
    assign(socket,
      form_errors: %{
        base:
          dgettext("dashboard_integrations", "That calendar connection is no longer available.")
      },
      copied_nextcloud_login: nil
    )
  end

  defp nextcloud_calendars(socket, :nextcloud_talk),
    do: Calendar.nextcloud_logins(socket.assigns.current_user.id)

  defp nextcloud_calendars(_socket, _provider), do: []

  # A copied login carries its app password only from here to the save: it is
  # read from the calendar integration at submit time and never kept in the
  # socket or sent to the browser. A password typed into the form wins, and a
  # server or login name changed since the copy gets no password at all, so
  # the calendar's password only ever goes to the account it belongs to.
  #
  # A calendar connection deleted or deactivated since the copy is reported as
  # such, rather than as a missing app password the organiser never had to type.
  defp with_copied_app_password(
         %{"provider" => "nextcloud_talk"} = submitted,
         %{id: calendar_id},
         user_id
       ) do
    with true <- blank?(submitted["client_secret"]),
         {:ok, login} <- Calendar.nextcloud_login(calendar_id, user_id) do
      if FormInput.copied_login_applies?(login, submitted),
        do: {:ok, Map.put(submitted, "client_secret", login.password)},
        else: {:ok, submitted}
    else
      false -> {:ok, submitted}
      {:error, :not_found} -> {:error, :copied_login_unavailable}
    end
  end

  defp with_copied_app_password(submitted, _copied_login, _user_id), do: {:ok, submitted}

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    notify_parent({:flash, {:error, message}})
    {:noreply, socket}
  end

  defp with_rate_limit(:ok, _socket, action), do: action.()

  defp load_integrations(socket) do
    user_id = socket.assigns.current_user.id
    integrations = Video.list_integrations(user_id)

    health_states =
      user_id
      |> HealthCheck.list_unhealthy_for_user()
      |> Enum.filter(&(&1.integration_type == "video"))
      |> Map.new(fn s -> {s.integration_id, Monitor.from_db_record(s)} end)

    socket
    |> assign(:integrations, integrations)
    |> assign(:health_states, health_states)
  end

  defp reset_form_state(socket) do
    assign(socket,
      config_provider: nil,
      form_errors: %{},
      saving: false,
      copied_nextcloud_login: nil
    )
  end

  defp initiate_oauth(socket, provider) do
    user_id = socket.assigns.current_user.id

    case Video.oauth_authorization_url(user_id, provider) do
      {:ok, url} ->
        notify_parent({:external_redirect, url})
        {:noreply, socket}

      {:error, error_message} ->
        notify_parent({:flash, {:error, error_message}})
        {:noreply, socket}
    end
  end

  defp notify_parent(msg), do: send(self(), msg)

  defp get_provider_name(socket, id) do
    case Enum.find(socket.assigns.integrations, &(&1.id == id)) do
      nil -> ""
      integration -> integration.provider
    end
  end
end
