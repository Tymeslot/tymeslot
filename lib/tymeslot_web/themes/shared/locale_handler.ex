defmodule TymeslotWeb.Themes.Shared.LocaleHandler do
  @moduledoc """
  Shared locale handling for scheduling LiveViews.
  Provides functions for managing locale in LiveView context.
  """

  alias Phoenix.Component

  @doc """
  Assigns the current locale to the socket from the connection assigns.
  Sets the locale in Gettext for the current process.
  """
  @spec assign_locale(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_locale(socket) do
    locale = socket.assigns[:locale] || default_locale()
    Gettext.put_locale(TymeslotWeb.Gettext, locale)
    Component.assign(socket, :locale, locale)
  end

  @doc """
  Changes the locale for the current socket.
  Validates that the new locale is supported before applying the change.

  The locale is applied to the current LiveView session. For session persistence
  across navigation, the locale should be included in URL params (via push_patch)
  which will be picked up by LocalePlug on subsequent page loads.

  Changes are idempotent to avoid unnecessary updates.
  """
  @spec handle_locale_change(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_locale_change(socket, new_locale) do
    current_locale = socket.assigns[:locale]

    # Always ensure Gettext is set for the current process
    # This handles cases where the process might have been reused or dictionary cleared
    if new_locale in supported_locales() do
      Gettext.put_locale(TymeslotWeb.Gettext, new_locale)
    end

    # Skip if locale is already set in assigns (idempotent for assigns)
    cond do
      new_locale == current_locale ->
        socket

      new_locale in supported_locales() ->
        # Update socket assigns
        # Note: For persistence across navigation, themes should use a full
        # redirect (external: true) with the locale in query params to ensure
        # the LocalePlug updates the session.
        Component.assign(socket, :locale, new_locale)

      true ->
        socket
    end
  end

  @doc """
  Returns the list of supported locale codes.
  Derived from the locale metadata configuration.
  """
  @spec supported_locales() :: [String.t()]
  def supported_locales do
    Enum.map(get_locales_with_metadata(), & &1.code)
  end

  @doc """
  Returns the full locale metadata including name and country code for UI rendering.
  """
  @spec get_locales_with_metadata() :: [map()]
  def get_locales_with_metadata do
    Application.get_env(:tymeslot, :locales)[:supported] || []
  end

  @doc """
  Returns the default locale code.
  """
  @spec default_locale() :: String.t()
  def default_locale do
    Application.get_env(:tymeslot, :locales)[:default] || "en"
  end
end
