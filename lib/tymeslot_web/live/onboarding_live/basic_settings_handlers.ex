defmodule TymeslotWeb.OnboardingLive.BasicSettingsHandlers do
  @moduledoc """
  Basic settings event handlers for the onboarding flow.

  Handles validation and updates for basic user profile settings
  including full name and username.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView
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

    case BasicSettingsShared.validate_basic_settings(socket, form_params) do
      {:ok, _sanitized_params} ->
        {:noreply, apply_validation_result(socket, updated_form_data, :ok)}

      {:error, errors} ->
        {:noreply, apply_validation_result(socket, updated_form_data, {:error, errors})}
    end
  end

  defp normalize_basic_settings_params(params) do
    case params do
      %{"basic_settings" => basic_settings} ->
        basic_settings

      %{"value" => value} when is_binary(value) ->
        # Parse URL-encoded form data
        URI.decode_query(value)

      # Use params directly if not nested
      _ ->
        params
    end
  end

  defp build_form_data(form_params, socket) do
    %{
      "full_name" => Map.get(form_params, "full_name", socket.assigns.form_data["full_name"]),
      "username" => Map.get(form_params, "username", socket.assigns.form_data["username"])
    }
  end

  defp apply_validation_result(socket, updated_form_data, :ok) do
    socket
    |> Component.assign(:form_data, updated_form_data)
    |> Component.assign(:form_errors, %{})
    |> LiveView.clear_flash()
  end

  defp apply_validation_result(socket, updated_form_data, {:error, errors}) do
    # Don't show username errors during typing, only show other validation errors
    socket
    |> Component.assign(:form_data, updated_form_data)
    |> Component.assign(:form_errors, Map.delete(errors, :username))
  end
end
