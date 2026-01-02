defmodule TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers do
  @moduledoc """
  Shared functionality for all dashboard LiveViews.
  Provides common assigns, mount logic, and utility functions.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [put_flash: 3]
  alias Tymeslot.{Profiles, Utils.ChangesetUtils}
  alias TymeslotWeb.Helpers.ClientIP
  require Logger

  @doc """
  Common mount logic for dashboard LiveViews.
  Sets up profile, saving state, and other common assigns.
  """
  @spec mount_dashboard_common(Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount_dashboard_common(socket) do
    user = socket.assigns.current_user

    # Get profile for the user (should exist after registration)
    profile = Profiles.get_profile(user.id)

    socket =
      socket
      |> assign(profile: profile)
      |> assign(saving: false)
      |> assign(dropdown_open: false)

    {:ok, socket}
  end

  @doc """
  Common saving animation logic.
  Shows saving indicator and hides it after specified duration.
  """
  @spec handle_saving_animation(Phoenix.LiveView.Socket.t(), non_neg_integer()) ::
          Phoenix.LiveView.Socket.t()
  def handle_saving_animation(socket, duration \\ 1000) do
    socket = assign(socket, saving: true)
    Process.send_after(self(), :hide_saving, duration)
    socket
  end

  @doc """
  Common error handling for changeset errors.
  """
  @spec handle_changeset_error(Phoenix.LiveView.Socket.t(), Ecto.Changeset.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_changeset_error(socket, changeset, default_message \\ "An error occurred") do
    Logger.error("Operation failed: #{inspect(changeset)}")

    error_msg = ChangesetUtils.get_first_error(changeset) || default_message

    socket
    |> put_flash(:error, error_msg)
    |> assign(saving: false)
  end

  @doc """
  Common success handling with flash message.
  """
  @spec handle_success(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def handle_success(socket, message, updated_assigns \\ %{}) do
    socket =
      socket
      |> put_flash(:info, message)
      |> assign(updated_assigns)

    # Hide saving animation after a delay
    Process.send_after(self(), :hide_saving, 1000)
    socket
  end

  @doc """
  Common hide_saving message handler.
  All dashboard LiveViews can use this.
  """
  @spec handle_hide_saving(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_hide_saving(socket) do
    {:noreply, assign(socket, saving: false)}
  end

  @doc """
  Gets remote IP from socket for security logging.
  """
  @spec get_remote_ip(Phoenix.LiveView.Socket.t()) :: String.t()
  def get_remote_ip(socket) do
    ClientIP.get(socket)
  end

  @doc """
  Gets security metadata from socket for input validation and logging.
  Provides consistent format across all dashboard components.
  Safe for both LiveViews and LiveComponents (where :current_user may not be present).
  """
  @spec get_security_metadata(Phoenix.LiveView.Socket.t()) :: map()
  def get_security_metadata(socket) do
    assigns = socket.assigns

    %{
      ip: compute_ip(assigns),
      user_agent: compute_user_agent(assigns),
      user_id: compute_user_id(assigns)
    }
  end

  defp compute_ip(assigns) do
    assigns[:client_ip] || assigns[:remote_ip] || "unknown"
  end

  defp compute_user_agent(assigns) do
    assigns[:user_agent] || "unknown"
  end

  defp compute_user_id(assigns) do
    cond do
      is_map_key(assigns, :current_user) and assigns.current_user ->
        assigns.current_user.id

      is_map_key(assigns, :profile) and assigns.profile ->
        Map.get(assigns.profile, :user_id) ||
          (Map.get(assigns.profile, :user) && Map.get(assigns.profile.user, :id))

      true ->
        nil
    end
  end

  @doc """
  Common page title helper.
  """
  @spec assign_page_title(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def assign_page_title(socket, title) do
    assign(socket, page_title: title)
  end

  @doc """
  Refreshes profile data from database.
  Useful after profile updates.
  """
  @spec refresh_profile(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_profile(socket) do
    user = socket.assigns.current_user
    updated_profile = Profiles.get_profile(user.id)
    assign(socket, profile: updated_profile)
  end

  @doc """
  Common dropdown toggle handler.
  Can be used in all dashboard LiveViews.
  """
  @spec handle_toggle_dropdown(Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_toggle_dropdown(socket) do
    {:noreply, assign(socket, dropdown_open: !socket.assigns.dropdown_open)}
  end
end
