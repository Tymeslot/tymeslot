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

  The link is normalised as it is typed (`Profiles.normalise_username/1`):
  the form data, and so the preview and what Continue saves, hold the
  normalised link at once. The field itself keeps what the host typed
  (`link_input`) while it has focus, so the value never changes under the
  cursor, and takes the normalised link on blur (`handle_link_blur/1`).
  """
  @spec handle_validate_basic_settings(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_basic_settings(params, socket) do
    typed_params = normalize_basic_settings_params(params)
    form_params = normalise_link(typed_params)
    {socket, updated_form_data} = follow_name(socket, build_form_data(form_params, socket))

    socket =
      Component.assign(
        socket,
        :link_input,
        link_input(typed_params["username"], updated_form_data)
      )

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

  @doc """
  Shows the normalised link in the field once the host leaves it.
  """
  @spec handle_link_blur(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_link_blur(socket), do: {:noreply, Component.assign(socket, :link_input, nil)}

  defp normalise_link(%{"username" => link} = form_params) when is_binary(link),
    do: %{form_params | "username" => Profiles.normalise_username(link)}

  defp normalise_link(form_params), do: form_params

  # What the field shows while it has focus: the typed text, when it is not
  # already the link the form holds. A suggestion that replaced the link is
  # shown as it is.
  defp link_input(typed, %{"username" => link}) when is_binary(typed) do
    if typed != link and Profiles.normalise_username(typed) == link, do: typed
  end

  defp link_input(_typed, _form_data), do: nil

  defp build_form_data(form_params, socket) do
    %{
      "full_name" => Map.get(form_params, "full_name", socket.assigns.form_data["full_name"]),
      "username" => Map.get(form_params, "username", socket.assigns.form_data["username"])
    }
  end

  # While the link is still a suggestion, a new name suggests a new link. A
  # change that alters the link to anything but the suggestion for the name
  # is the host typing their own, which is never overwritten from then on.
  # A link that is the suggestion is still one: that is what a reconnect's
  # form recovery sends back after the host had changed the name.
  defp follow_name(socket, %{"username" => username} = form_data) do
    previous = socket.assigns.form_data

    cond do
      username == previous["username"] and form_data["full_name"] == previous["full_name"] ->
        {socket, form_data}

      username != previous["username"] and not suggestion?(socket, form_data) ->
        {Component.assign(socket, :link_suggested, false), form_data}

      socket.assigns.link_suggested and form_data["full_name"] != previous["full_name"] ->
        link =
          BasicSettingsShared.suggest_link(socket.assigns.current_user, form_data["full_name"])

        {socket, %{form_data | "username" => link}}

      true ->
        {socket, form_data}
    end
  end

  defp suggestion?(%{assigns: %{link_suggested: true}} = socket, form_data),
    do:
      form_data["username"] ==
        BasicSettingsShared.suggest_link(socket.assigns.current_user, form_data["full_name"])

  defp suggestion?(_socket, _form_data), do: false

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

  # The link's error is shown as the host types, in the step's words: its
  # shape (`BasicSettingsShared.link_error/1`), or that it is reserved or
  # taken. The profile's own current handle is never re-checked.
  defp resolve_username_error(errors, form_data, socket) do
    errors = Map.delete(errors, :username)
    link = form_data["username"] || ""

    case Profiles.username_status(socket.assigns[:profile], link) do
      reason when reason in [:reserved, :taken] ->
        Map.put(errors, :username, username_error(reason))

      {:invalid, _message} ->
        Map.put(errors, :username, BasicSettingsShared.link_error(link))

      _unchanged_or_ok ->
        errors
    end
  end

  defp username_error(:reserved),
    do: dgettext("onboarding_wizard", "This link is reserved. Try another one.")

  defp username_error(:taken),
    do: dgettext("onboarding_wizard", "Someone already has this link. Try another one.")
end
