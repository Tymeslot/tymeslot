defmodule TymeslotWeb.OnboardingLive.CalendarHandlers do
  @moduledoc """
  Calendar connection event handlers for the onboarding flow.

  Choosing a tile acts at once: Google and Outlook go out to the provider's
  sign-in, while Apple Calendar and other CalDAV servers open an inline
  credential form whose discovery and integration creation run in the
  background. Apple Calendar is the CalDAV family's iCloud member (`:apple`),
  whose server address is fixed, so its form asks only for the Apple ID
  email and an app-specific password.

  A calendar that makes the page bookable starts the reveal of the host's
  week on the stage (`WeekReveal`).
  """

  use TymeslotWeb, :verified_routes
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Auth
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.InputValidation, as: CalendarInputValidation
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias TymeslotWeb.OnboardingLive.NavigationHandlers
  alias TymeslotWeb.OnboardingLive.ThemeHandlers
  alias TymeslotWeb.OnboardingLive.WeekReveal

  require Logger
  require Phoenix.LiveView

  @doc """
  Initiates Google Calendar OAuth and redirects the user externally.
  """
  @spec handle_connect_google(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_connect_google(socket) do
    user = socket.assigns.current_user

    opts =
      maybe_put_login_hint(
        [return_to: oauth_return_path(socket)],
        Auth.google_signup_login_hint(user)
      )

    case Calendar.initiate_oauth(:google, user.id, opts) do
      {:ok, url} ->
        {:noreply, LiveView.redirect(socket, external: url)}

      {:error, msg} ->
        {:noreply, LiveView.put_flash(socket, :error, msg)}
    end
  end

  # A host sent back from the share step keeps that through the provider's
  # redirect, so connecting still leads straight back to the share step.
  defp oauth_return_path(%{assigns: %{returning_to_share: true}}),
    do: ~p"/onboarding/connect_calendar?#{[return: "share"]}"

  defp oauth_return_path(_socket), do: ~p"/onboarding/connect_calendar"

  defp maybe_put_login_hint(opts, nil), do: opts
  defp maybe_put_login_hint(opts, email), do: Keyword.put(opts, :login_hint, email)

  @doc """
  Initiates Outlook Calendar OAuth and redirects the user externally.
  """
  @spec handle_connect_outlook(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_connect_outlook(socket) do
    user_id = socket.assigns.current_user.id

    case Calendar.initiate_oauth(:outlook, user_id, return_to: oauth_return_path(socket)) do
      {:ok, url} ->
        {:noreply, LiveView.redirect(socket, external: url)}

      {:error, msg} ->
        {:noreply, LiveView.put_flash(socket, :error, msg)}
    end
  end

  @doc """
  Acts on the tile the host chose: the OAuth providers redirect out, and
  Apple Calendar and CalDAV open their inline form. Anything else, such as a
  forged option, is ignored.
  """
  @spec handle_choose_provider(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_choose_provider("google", socket), do: handle_connect_google(socket)
  def handle_choose_provider("outlook", socket), do: handle_connect_outlook(socket)
  def handle_choose_provider("apple", socket), do: open_form(socket, :connecting_apple)
  def handle_choose_provider("caldav", socket), do: open_form(socket, :connecting_caldav)
  def handle_choose_provider(_option, socket), do: {:noreply, socket}

  @doc """
  Reconnects one of the host's paused calendars, named by id: an OAuth
  provider goes out to its sign-in again, whose return switches the
  calendar back on; Apple Calendar and CalDAV open their form to take a new
  password. An id that is not one of the host's calendars is ignored.
  """
  @spec handle_reconnect(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_reconnect(id, socket) do
    with {id, ""} <- Integer.parse(id),
         %{} = calendar <- Enum.find(socket.assigns.connected_calendars, &(&1.id == id)) do
      reconnect(calendar, socket)
    else
      _not_theirs -> {:noreply, socket}
    end
  end

  defp reconnect(%{provider: "google"}, socket), do: handle_connect_google(socket)
  defp reconnect(%{provider: "outlook"}, socket), do: handle_connect_outlook(socket)

  defp reconnect(%{provider: "apple"} = calendar, socket),
    do: open_form(socket, :connecting_apple, calendar)

  defp reconnect(calendar, socket) do
    if ProviderConfig.caldav_based?(calendar.provider),
      do: open_form(socket, :connecting_caldav, calendar),
      else: {:noreply, socket}
  end

  # A reconnect starts from what is known of the calendar, bar its password.
  # The control that opened the form is gone with the tiles, so the focus
  # moves to the form's first field.
  defp open_form(socket, state, calendar \\ nil) do
    first_field = if state == :connecting_apple, do: "apple_username", else: "caldav_url"

    {:noreply,
     socket
     |> Component.assign(
       calendar_state: state,
       reconnecting_calendar: calendar && calendar.id,
       caldav_form_data: known_fields(calendar),
       caldav_form_errors: %{}
     )
     |> LiveView.push_event("focus", %{id: first_field})}
  end

  defp known_fields(nil), do: %{}

  defp known_fields(calendar),
    do: %{"url" => calendar.base_url || "", "username" => Map.get(calendar, :username) || ""}

  @doc """
  Cancels the Apple Calendar or CalDAV form and returns to the tiles, with
  the focus back on the tile that opened it.
  """
  @spec handle_cancel_caldav(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_caldav(socket) do
    tile = "calendar-provider-#{form_provider(socket)}"

    {:noreply,
     socket
     |> Component.assign(
       calendar_state: :selecting,
       reconnecting_calendar: nil,
       caldav_form_data: %{},
       caldav_form_errors: %{},
       caldav_discovering: false
     )
     |> LiveView.push_event("focus", %{id: tile})}
  end

  @doc """
  Validates CalDAV form fields on change.
  """
  @spec handle_validate_caldav(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_caldav(params, socket) do
    form_data = extract_caldav_params(params)
    errors = validate_caldav_fields(form_provider(socket), form_data)

    {:noreply,
     socket
     |> Component.assign(:caldav_form_data, form_data)
     |> Component.assign(:caldav_form_errors, errors)}
  end

  @doc """
  Discovers calendars from CalDAV server and creates the integration.
  """
  @spec handle_discover_caldav(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_discover_caldav(params, socket) do
    form_data = extract_caldav_params(params)
    errors = validate_caldav_fields(form_provider(socket), form_data)

    if map_size(errors) > 0 do
      {:noreply,
       socket
       |> Component.assign(:caldav_form_data, form_data)
       |> Component.assign(:caldav_form_errors, errors)}
    else
      discover_and_create_caldav(socket, form_data)
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp extract_caldav_params(params) do
    caldav_params = Map.get(params, "caldav", params)

    %{
      "url" => Map.get(caldav_params, "url", ""),
      "username" => Map.get(caldav_params, "username", ""),
      "password" => Map.get(caldav_params, "password", "")
    }
  end

  # The form on screen: Apple Calendar's, or the generic CalDAV one.
  defp form_provider(%{assigns: %{calendar_state: :connecting_apple}}), do: :apple
  defp form_provider(_socket), do: :caldav

  # A blank field is named as missing; anything else gets the same checks
  # the dashboard's connection form makes as the host types. Apple
  # Calendar's server is fixed, so its form has no address to check.
  defp validate_caldav_fields(provider, form_data) do
    for {key, field, missing} <- required_fields(provider),
        error <- [field_error(Map.get(form_data, key, ""), field, missing)],
        error != nil,
        into: %{},
        do: {field, error}
  end

  defp required_fields(:apple) do
    [
      {"username", :username, dgettext("onboarding_wizard", "Apple ID email is required")},
      {"password", :password, dgettext("onboarding_wizard", "Password is required")}
    ]
  end

  defp required_fields(:caldav) do
    [
      {"url", :url, dgettext("onboarding_wizard", "Server URL is required")},
      {"username", :username, dgettext("onboarding_wizard", "Username is required")},
      {"password", :password, dgettext("onboarding_wizard", "Password is required")}
    ]
  end

  defp field_error(value, field, missing) do
    if String.trim(value) == "" do
      missing
    else
      case CalendarInputValidation.validate_single_field(field, value) do
        {:ok, _sanitized} -> nil
        {:error, message} -> message
      end
    end
  end

  # CalDAV discovery and integration creation both make blocking network
  # round-trips to the remote server. Running them inline in handle_event would
  # freeze the LiveView process, so the "Discover calendars" button could never
  # render its loading state. Kick the work off with start_async and let
  # handle_discover_caldav_result/2 fold the outcome back into the socket.
  defp discover_and_create_caldav(socket, form_data) do
    if socket.assigns.caldav_discovering do
      {:noreply, socket}
    else
      user_id = socket.assigns.current_user.id
      provider = form_provider(socket)
      reconnecting = socket.assigns.reconnecting_calendar

      {:noreply,
       socket
       |> Component.assign(:caldav_discovering, true)
       |> Component.assign(:caldav_form_data, form_data)
       |> Component.assign(:caldav_form_errors, %{})
       |> LiveView.start_async(
         :discover_caldav,
         Tasks.with_context(fn ->
           run_caldav_discovery(provider, user_id, reconnecting, form_data)
         end)
       )}
    end
  end

  # Runs in the async task process — must not touch the socket. Returns a
  # tagged result the LiveView folds back in via handle_discover_caldav_result/2.
  defp run_caldav_discovery(provider, user_id, nil, form_data) do
    url = server_url(provider, form_data)
    username = form_data["username"]
    password = form_data["password"]

    case Calendar.discover_and_filter_calendars(provider, url, username, password, user_id) do
      {:ok, %{discovery_credentials: credentials}} ->
        params = %{
          "provider" => Atom.to_string(provider),
          "name" => integration_name(provider),
          "url" => credentials[:url] || url,
          "username" => credentials[:username] || username,
          "password" => credentials[:password] || password
        }

        case Calendar.create_integration_with_validation(user_id, params) do
          {:ok, _integration} -> :created
          {:error, {:form_errors, errors}} -> {:form_errors, errors}
          {:error, reason} -> {:creation_failed, reason}
        end

      {:error, reason} ->
        {:discovery_failed, reason}
    end
  end

  # A paused calendar takes the new password and is switched back on, keeping
  # the calendars it had.
  defp run_caldav_discovery(provider, user_id, integration_id, form_data) do
    params = %{
      "url" => server_url(provider, form_data),
      "username" => form_data["username"],
      "password" => form_data["password"]
    }

    case Calendar.reconnect_and_resume_caldav_integration(user_id, integration_id, params) do
      {:ok, _integration} -> :created
      {:error, reason} -> {:reconnect_failed, reason}
    end
  end

  # iCloud runs on one host, the one the dashboard's Apple form locks in.
  defp server_url(:apple, _form_data), do: ProviderConfig.locked_url_for(:apple).url
  defp server_url(:caldav, form_data), do: form_data["url"]

  defp integration_name(:apple), do: dgettext("onboarding_wizard", "Apple Calendar")
  defp integration_name(:caldav), do: dgettext("onboarding_wizard", "CalDAV Calendar")

  @doc """
  Folds a CalDAV discovery async result back into the socket. Dispatched from
  `OnboardingLive.handle_async/3`.
  """
  @spec handle_discover_caldav_result(
          {:ok, term()} | {:exit, term()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_discover_caldav_result({:ok, :created}, socket) do
    socket
    |> refresh_connected_calendars()
    |> maybe_reset_caldav_step()
    |> then(&{:noreply, Component.assign(&1, :caldav_discovering, false)})
  end

  def handle_discover_caldav_result({:ok, {:form_errors, errors}}, socket) do
    {:noreply,
     socket
     |> Component.assign(:caldav_form_errors, errors)
     |> Component.assign(:caldav_discovering, false)}
  end

  def handle_discover_caldav_result({:ok, {:creation_failed, reason}}, socket) do
    Logger.warning("CalDAV integration creation failed",
      user_id: socket.assigns.current_user.id,
      reason: LogFormat.reason(reason)
    )

    {:noreply,
     socket
     |> Component.assign(:caldav_form_errors, %{
       discovery:
         dgettext("onboarding_wizard", "Could not create calendar integration. Please try again.")
     })
     |> Component.assign(:caldav_discovering, false)}
  end

  def handle_discover_caldav_result({:ok, {:reconnect_failed, reason}}, socket) do
    {:noreply,
     socket
     |> Component.assign(:caldav_form_errors, %{discovery: reconnect_error(reason)})
     |> Component.assign(:caldav_discovering, false)}
  end

  def handle_discover_caldav_result({:ok, {:discovery_failed, reason}}, socket) do
    {:noreply,
     socket
     |> Component.assign(:caldav_form_errors, %{
       discovery: DisplayHelpers.normalize_discovery_error(reason)
     })
     |> Component.assign(:caldav_discovering, false)}
  end

  def handle_discover_caldav_result({:exit, reason}, socket) do
    Logger.error("CalDAV discovery task crashed",
      user_id: socket.assigns.current_user.id,
      reason: LogFormat.reason(reason)
    )

    {:noreply,
     socket
     |> Component.assign(:caldav_form_errors, %{
       discovery:
         dgettext(
           "onboarding_wizard",
           "Something went wrong while contacting the calendar server. Please try again."
         )
     })
     |> Component.assign(:caldav_discovering, false)}
  end

  # The dashboard's own wording for each way a reconnect is refused.
  defp reconnect_error(:invalid_credentials),
    do: dgettext("dashboard_calendar_providers", "Could not sign in with those credentials")

  defp reconnect_error(:duplicate_account),
    do:
      dgettext(
        "dashboard_calendar_settings",
        "Cannot reactivate - another active integration already uses this account"
      )

  defp reconnect_error(:not_found),
    do: dgettext("dashboard_calendar_providers", "Integration not found")

  defp reconnect_error(message) when is_binary(message), do: message
  defp reconnect_error(reason), do: DisplayHelpers.connection_error_message(reason)

  defp refresh_connected_calendars(socket) do
    user_id = socket.assigns.current_user.id
    connected = Calendar.list_integrations(user_id)
    ThemeHandlers.seed_video_backgrounds(socket.assigns.profile, connected)

    socket
    |> Component.assign(:connected_calendars, connected)
    |> NavigationHandlers.assign_booking_page_live()
    |> WeekReveal.maybe_start()
  end

  # The async result can settle after the user has already navigated away from
  # the connect-calendar step (e.g. clicked Back mid-discovery). Only reset the
  # CalDAV step's UI state while the user is still looking at it — resetting it
  # from elsewhere would silently rewrite the state of a step no longer shown.
  defp maybe_reset_caldav_step(%{assigns: %{current_step: :connect_calendar}} = socket) do
    socket
    |> Component.assign(:calendar_state, :selecting)
    |> Component.assign(:reconnecting_calendar, nil)
    |> Component.assign(:caldav_form_data, %{})
    |> Component.assign(:caldav_form_errors, %{})
  end

  defp maybe_reset_caldav_step(socket), do: socket
end
