defmodule TymeslotWeb.OnboardingLive.ProfileHandlers do
  @moduledoc """
  Profile step event handlers for the onboarding flow.

  Handles validation and updates for basic user profile settings
  including full name and username.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles
  alias Tymeslot.Security.FieldValidators.UsernameValidator
  alias TymeslotWeb.OnboardingLive.BasicSettingsShared

  @doc """
  Handles validation of basic settings form data.

  Validates user input in real-time and updates form state
  with validation results.
  """
  @spec handle_validate_basic_settings(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_basic_settings(params, socket) do
    form_params = normalize_basic_settings_params(params)
    updated_form_data = build_form_data(form_params, socket)

    base_errors =
      case BasicSettingsShared.validate_basic_settings(socket, form_params) do
        {:ok, _sanitized_params} -> %{}
        {:error, errors} -> errors
      end

    errors = resolve_username_error(base_errors, updated_form_data, socket)

    {:noreply, apply_validation_result(socket, updated_form_data, errors)}
  end

  defp normalize_basic_settings_params(params) do
    case params do
      %{"basic_settings" => basic_settings} ->
        basic_settings

      %{"value" => value} when is_binary(value) ->
        # Parse URL-encoded form data
        URI.decode_query(value)

      # Use params directly if not nested
      _other ->
        params
    end
  end

  defp build_form_data(form_params, socket) do
    %{
      "full_name" => Map.get(form_params, "full_name", socket.assigns.form_data["full_name"]),
      "username" => Map.get(form_params, "username", socket.assigns.form_data["username"])
    }
  end

  defp apply_validation_result(socket, updated_form_data, errors) when errors == %{} do
    socket
    |> Component.assign(:form_data, updated_form_data)
    |> Component.assign(:form_errors, %{})
    |> LiveView.clear_flash()
  end

  defp apply_validation_result(socket, updated_form_data, errors) do
    socket
    |> Component.assign(:form_data, updated_form_data)
    |> Component.assign(:form_errors, errors)
  end

  # Username errors fall into two buckets. Format/length problems ("too short",
  # bad characters) are nags while the user is mid-keystroke, so we suppress
  # them live and let the changeset surface them on continue. But "reserved"
  # and "already taken" are decisive — the name can never work — so we show
  # them immediately, exactly as a collision would feel. The reserved/taken
  # checks only run once the username is otherwise valid and actually changed
  # from the profile's own current handle.
  defp resolve_username_error(errors, form_data, socket) do
    errors = Map.delete(errors, :username)
    username = String.trim(form_data["username"] || "")
    profile = socket.assigns[:profile]

    cond do
      username == "" ->
        errors

      profile && profile.username == username ->
        errors

      UsernameValidator.validate(username) != :ok ->
        errors

      username in Profiles.reserved_paths() ->
        Map.put(errors, :username, "This username is reserved")

      not Profiles.username_available?(username) ->
        Map.put(errors, :username, "This username is already taken")

      true ->
        errors
    end
  end
end
