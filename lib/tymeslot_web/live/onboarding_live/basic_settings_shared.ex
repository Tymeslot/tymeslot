defmodule TymeslotWeb.OnboardingLive.BasicSettingsShared do
  @moduledoc """
  Shared helpers for onboarding basic settings validation and persistence.
  """

  alias Phoenix.Component
  alias Tymeslot.Profiles
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
  def persist_basic_settings(socket, sanitized_params, opts) do
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
  Assigns the profile step's form from the current user and profile on the
  socket (the profile may still be `nil` on a first visit).

  The name is the profile's, else the account's, never a placeholder. A host with no link of
  their own yet (blank, or the generated default) gets one suggested from
  that name, or failing it their email, and `link_suggested` is set: until
  they type in the link field, a new name replaces the suggestion. The
  suggestion is a field value only; nothing is written until Continue.
  """
  @spec assign_form_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_form_data(socket) do
    user = socket.assigns.current_user
    profile = socket.assigns.profile
    # The name on the profile is the one the host last saved here, so Back
    # shows it; the account's name stands in until there is one.
    full_name = Enum.find([profile && profile.full_name, user.name], "", &present?/1)
    username = profile && profile.username
    suggested? = Profiles.default_username?(username, user.id)

    Component.assign(socket,
      form_data: %{
        "full_name" => full_name,
        "username" => if(suggested?, do: suggest_link(user, full_name), else: username)
      },
      link_suggested: suggested?
    )
  end

  defp present?(name), do: is_binary(name) and String.trim(name) != ""

  @doc """
  The booking link suggested for `user` under `full_name`.
  """
  @spec suggest_link(map(), String.t() | nil) :: String.t()
  def suggest_link(user, full_name),
    do: Profiles.suggest_username(full_name, user.id, email: user.email)

  @doc """
  Applies validation errors to the socket.
  """
  @spec apply_validation_errors(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def apply_validation_errors(socket, errors) do
    Component.assign(socket, :form_errors, errors)
  end
end
