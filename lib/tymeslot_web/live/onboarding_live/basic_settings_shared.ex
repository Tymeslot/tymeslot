defmodule TymeslotWeb.OnboardingLive.BasicSettingsShared do
  @moduledoc """
  Shared helpers for onboarding basic settings validation and persistence.
  """

  alias Phoenix.Component
  alias Tymeslot.Profiles.Settings
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Builds the metadata map required for onboarding input validation.
  """
  @spec metadata(Phoenix.LiveView.Socket.t()) :: map()
  def metadata(socket) do
    %{
      ip: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket)
    }
  end

  @doc """
  Validates the given params using the onboarding input processor.
  """
  @spec validate_basic_settings(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, map()} | {:error, map()}
  @basic_settings_field_spec [{"full_name", :full_name}, {"username", :username}]

  def validate_basic_settings(socket, params) do
    InputProcessor.validate_form(
      params,
      @basic_settings_field_spec,
      metadata: metadata(socket),
      universal_opts: [allow_html: false]
    )
  end

  @doc """
  Persists the sanitized params to the profile. Optionally preserves the existing timezone.
  """
  @spec persist_basic_settings(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
          {:ok, Tymeslot.Profiles.ProfileSchema.t()} | {:error, {:update_failed, term()}}
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
  Builds the initial form_data map from the current user and profile on the socket.
  """
  @spec build_form_data(Phoenix.LiveView.Socket.t()) :: map()
  def build_form_data(socket) do
    user = socket.assigns.current_user
    profile = socket.assigns.profile

    %{
      "full_name" => user.name || profile.full_name || "",
      "username" => profile.username || ""
    }
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
