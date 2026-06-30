defmodule TymeslotWeb.OnboardingLive.CalendarHandlers do
  @moduledoc """
  Calendar connection event handlers for the onboarding flow.

  Handles OAuth initiation for Google and Outlook, inline CalDAV
  credential entry, calendar discovery, and integration creation.
  """

  use TymeslotWeb, :verified_routes

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Auth
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.OnboardingLive.StepConfig
  alias TymeslotWeb.OnboardingLive.ThemeHandlers

  require Logger

  @doc """
  Initiates Google Calendar OAuth and redirects the user externally.
  """
  @spec handle_connect_google(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_connect_google(socket) do
    user = socket.assigns.current_user

    opts =
      maybe_put_login_hint(
        [return_to: ~p"/onboarding/connect_calendar"],
        Auth.google_signup_login_hint(user)
      )

    case Calendar.initiate_google_oauth(user.id, opts) do
      {:ok, url} ->
        {:noreply, LiveView.redirect(socket, external: url)}

      {:error, msg} ->
        {:noreply, LiveView.put_flash(socket, :error, msg)}
    end
  end

  defp maybe_put_login_hint(opts, nil), do: opts
  defp maybe_put_login_hint(opts, email), do: Keyword.put(opts, :login_hint, email)

  @doc """
  Initiates Outlook Calendar OAuth and redirects the user externally.
  """
  @spec handle_connect_outlook(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_connect_outlook(socket) do
    user_id = socket.assigns.current_user.id

    case Calendar.initiate_outlook_oauth(user_id, return_to: ~p"/onboarding/connect_calendar") do
      {:ok, url} ->
        {:noreply, LiveView.redirect(socket, external: url)}

      {:error, msg} ->
        {:noreply, LiveView.put_flash(socket, :error, msg)}
    end
  end

  @doc """
  Records the user's pending calendar choice without connecting. The actual
  connection (or skip) happens when the user presses Continue. Selecting the
  already-chosen option toggles it off, clearing the selection.
  """
  @spec handle_select_option(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_select_option(option, socket) when option in ~w(google outlook caldav skip) do
    choice = if socket.assigns.calendar_choice == option, do: nil, else: option
    {:noreply, Component.assign(socket, :calendar_choice, choice)}
  end

  def handle_select_option(_option, socket), do: {:noreply, socket}

  @doc """
  Cancels CalDAV form and returns to provider selection.
  """
  @spec handle_cancel_caldav(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_caldav(socket) do
    {:noreply,
     socket
     |> Component.assign(:calendar_state, :selecting)
     |> Component.assign(:caldav_form_data, %{})
     |> Component.assign(:caldav_form_errors, %{})}
  end

  @doc """
  Validates CalDAV form fields on change.
  """
  @spec handle_validate_caldav(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_caldav(params, socket) do
    form_data = extract_caldav_params(params)
    errors = validate_caldav_fields(form_data)

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
    errors = validate_caldav_fields(form_data)

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

  defp validate_caldav_fields(form_data) do
    []
    |> maybe_add_error(form_data, "url", :url, "Server URL is required")
    |> maybe_add_error(form_data, "username", :username, "Username is required")
    |> maybe_add_error(form_data, "password", :password, "Password is required")
    |> Map.new()
  end

  defp maybe_add_error(errors, form_data, key, error_key, message) do
    value = Map.get(form_data, key, "")

    if String.trim(value) == "" do
      [{error_key, message} | errors]
    else
      errors
    end
  end

  defp discover_and_create_caldav(socket, form_data) do
    user_id = socket.assigns.current_user.id
    url = form_data["url"]
    username = form_data["username"]
    password = form_data["password"]

    case Calendar.discover_and_filter_calendars(:caldav, url, username, password) do
      {:ok, %{calendars: _calendars, discovery_credentials: credentials}} ->
        integration_params = %{
          "provider" => "caldav",
          "name" => "CalDAV Calendar",
          "url" => credentials[:url] || url,
          "username" => credentials[:username] || username,
          "password" => credentials[:password] || password
        }

        case Calendar.create_integration_with_validation(user_id, integration_params) do
          {:ok, _integration} ->
            connected = Calendar.list_integrations(user_id)
            ThemeHandlers.seed_video_backgrounds(socket.assigns.profile, connected)

            {:noreply,
             socket
             |> Component.assign(:connected_calendars, connected)
             |> Component.assign(:steps, StepConfig.steps(connected != []))
             |> Component.assign(:calendar_state, :selecting)
             |> Component.assign(:calendar_choice, nil)
             |> Component.assign(:caldav_form_data, %{})
             |> Component.assign(:caldav_form_errors, %{})}

          {:error, {:form_errors, errors}} ->
            {:noreply, Component.assign(socket, :caldav_form_errors, errors)}

          {:error, reason} ->
            Logger.warning("CalDAV integration creation failed",
              user_id: user_id,
              reason: inspect(reason)
            )

            {:noreply,
             Component.assign(socket, :caldav_form_errors, %{
               discovery: "Could not create calendar integration. Please try again."
             })}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> Component.assign(:caldav_form_data, form_data)
         |> Component.assign(:caldav_form_errors, %{
           discovery: DisplayHelpers.normalize_discovery_error(reason)
         })}
    end
  end
end
