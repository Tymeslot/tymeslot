defmodule TymeslotWeb.OnboardingLive.BasicSettingsShared do
  @moduledoc """
  Shared helpers for onboarding basic settings validation and persistence.
  """

  alias Phoenix.Component
  alias Tymeslot.Profiles.Settings
  alias Tymeslot.Security.OnboardingInputProcessor
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Builds the metadata map required for onboarding input validation.
  """
  @spec metadata(Phoenix.LiveView.Socket.t()) :: map()
  def metadata(socket) do
    %{
      ip: socket.assigns[:client_ip] || "unknown",
      user_agent: ClientIP.get_user_agent(socket)
    }
  end

  @doc """
  Validates the given params using the onboarding input processor.
  """
  @spec validate_basic_settings(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, map()} | {:error, map()}
  def validate_basic_settings(socket, params) do
    OnboardingInputProcessor.validate_basic_settings(params, metadata: metadata(socket))
  end

  @doc """
  Persists the sanitized params to the profile. Optionally preserves the existing timezone.
  """
  @spec persist_basic_settings(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
          {:ok, Tymeslot.DatabaseSchemas.ProfileSchema.t()} | {:error, {:update_failed, term()}}
  def persist_basic_settings(socket, sanitized_params, opts \\ []) do
    params =
      if Keyword.get(opts, :preserve_timezone, false) do
        Map.put_new(sanitized_params, "timezone", socket.assigns.profile.timezone)
      else
        sanitized_params
      end

    case Settings.update_basic_settings(socket.assigns.profile, params) do
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, {:update_failed, reason}}
    end
  end

  @doc """
  Applies validation errors to the socket.
  """
  @spec apply_validation_errors(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def apply_validation_errors(socket, errors) do
    Component.assign(socket, :form_errors, errors)
  end
end
