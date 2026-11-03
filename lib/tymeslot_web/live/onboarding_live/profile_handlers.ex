defmodule TymeslotWeb.OnboardingLive.ProfileHandlers do
  @moduledoc """
  Profile step event handlers for the onboarding flow.

  Handles validation and updates for basic user profile settings
  including full name and username.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles
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
    {socket, updated_form_data} = follow_name(socket, build_form_data(form_params, socket))

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

  # While the link is still a suggestion, a new name suggests a new link. A
  # change that alters the link itself is the host typing their own, which
  # is never overwritten from then on. The link field may be focused when a
  # suggestion arrives, and a browser keeps a focused field's value, so the
  # next change then carries what the host sees and settles it as theirs.
  defp follow_name(socket, %{"username" => username} = form_data) do
    previous = socket.assigns.form_data

    cond do
      username != previous["username"] ->
        {Component.assign(socket, :link_suggested, false), form_data}

      socket.assigns.link_suggested and form_data["full_name"] != previous["full_name"] ->
        link =
          BasicSettingsShared.suggest_link(socket.assigns.current_user, form_data["full_name"])

        {socket, %{form_data | "username" => link}}

      true ->
        {socket, form_data}
    end
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

  @doc """
  Puts the inline username error explaining why a username is `:reserved` or
  `:taken`, keeping any errors already shown for other fields.
  """
  @spec put_username_error(Phoenix.LiveView.Socket.t(), :reserved | :taken) ::
          Phoenix.LiveView.Socket.t()
  def put_username_error(socket, reason) do
    errors = Map.get(socket.assigns, :form_errors, %{})
    Component.assign(socket, :form_errors, Map.put(errors, :username, username_error(reason)))
  end

  # Username errors fall into two buckets. Format/length problems ("too short",
  # bad characters) are nags while the user is mid-keystroke, so we suppress
  # them live and let the changeset surface them on continue. But "reserved"
  # and "already taken" are decisive — the name can never work — so we show
  # them immediately, exactly as a collision would feel. The profile's own
  # current handle is never re-checked.
  defp resolve_username_error(errors, form_data, socket) do
    errors = Map.delete(errors, :username)

    case Profiles.username_status(socket.assigns[:profile], form_data["username"] || "") do
      reason when reason in [:reserved, :taken] ->
        Map.put(errors, :username, username_error(reason))

      _unchanged_ok_or_invalid ->
        errors
    end
  end

  defp username_error(:reserved), do: dgettext("onboarding_wizard", "This username is reserved")
  defp username_error(:taken), do: dgettext("onboarding_wizard", "This username is already taken")
end
