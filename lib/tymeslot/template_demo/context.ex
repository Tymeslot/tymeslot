defmodule Tymeslot.TemplateDemo.Context do
  @moduledoc """
  Context management for template_demo mode operations.

  This module provides functions to manage demo mode state and check
  whether the application is operating in demo mode for the template demo flow.
  """

  alias Phoenix.Component

  @doc """
  Adds demo mode flag to the socket assigns.
  """
  @spec put_demo_mode(map(), boolean()) :: map()
  def put_demo_mode(socket, demo_mode) when is_boolean(demo_mode) do
    Component.assign(socket, :demo_mode, demo_mode)
  end

  @doc """
  Checks if the socket is in demo mode.

  This checks for demo mode based on:
  1. Explicit demo_mode flag
  2. Demo username context
  3. Demo organizer user ID
  """
  @spec demo_mode?(map()) :: boolean()
  def demo_mode?(socket) do
    case socket do
      %{assigns: %{demo_mode: true}} ->
        true

      %{assigns: %{username_context: username}} when is_binary(username) ->
        demo_username?(username)

      %{assigns: %{organizer_user_id: user_id}} when user_id in [999_001, 999_002] ->
        true

      _ ->
        false
    end
  end

  @doc """
  Checks if a username is a template demo username.
  """
  @spec demo_username?(term()) :: boolean()
  def demo_username?(username) when is_binary(username) do
    String.starts_with?(username, "demo-theme-")
  end

  def demo_username?(_), do: false

  @doc """
  Extracts theme ID from template demo username.
  """
  @spec get_theme_id_from_username(term()) :: String.t() | nil
  def get_theme_id_from_username("demo-theme-" <> theme_id), do: theme_id
  def get_theme_id_from_username(_), do: nil

  @doc """
  Gets the appropriate orchestrator based on template_demo mode.
  """
  @spec get_orchestrator(map()) :: module()
  def get_orchestrator(socket) do
    if demo_mode?(socket) do
      Tymeslot.Bookings.DemoOrchestrator
    else
      Tymeslot.Bookings.Orchestrator
    end
  end
end
