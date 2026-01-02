defmodule TymeslotWeb.AccountLive.Helpers do
  @moduledoc """
  Helper functions for account management.
  Provides state management and formatting utilities.
  """

  import Phoenix.Component, only: [assign: 3]

  # Provider constants
  @email_provider "email"

  @doc """
  Initializes form state for the account settings page.
  """
  @spec init_form_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init_form_state(socket) do
    socket
    |> assign(:email_form_errors, %{})
    |> assign(:password_form_errors, %{})
    |> assign(:show_email_form, false)
    |> assign(:show_password_form, false)
    |> assign(:saving_email, false)
    |> assign(:saving_password, false)
    |> assign(:is_social_user, social_user?(socket.assigns.current_user))
  end

  @doc """
  Toggles the visibility of a form section.
  """
  @spec toggle_form(Phoenix.LiveView.Socket.t(), :email | :password) ::
          Phoenix.LiveView.Socket.t()
  def toggle_form(socket, :email) do
    socket
    |> assign(:show_email_form, !socket.assigns.show_email_form)
    |> assign(:email_form_errors, %{})
  end

  def toggle_form(socket, :password) do
    socket
    |> assign(:show_password_form, !socket.assigns.show_password_form)
    |> assign(:password_form_errors, %{})
  end

  @doc """
  Resets form state after successful update.
  """
  @spec reset_form_state(Phoenix.LiveView.Socket.t(), :email | :password, Ecto.Schema.t()) ::
          Phoenix.LiveView.Socket.t()
  def reset_form_state(socket, :email, updated_user) do
    socket
    |> assign(:current_user, updated_user)
    |> assign(:show_email_form, false)
    |> assign(:email_form_errors, %{})
    |> assign(:saving_email, false)
  end

  def reset_form_state(socket, :password, updated_user) do
    socket
    |> assign(:current_user, updated_user)
    |> assign(:show_password_form, false)
    |> assign(:password_form_errors, %{})
    |> assign(:saving_password, false)
  end

  @doc """
  Formats the last password change date for display.
  """
  @spec format_last_password_change(Ecto.Schema.t()) :: String.t()
  def format_last_password_change(user) do
    if user.updated_at do
      Calendar.strftime(user.updated_at, "%B %d, %Y")
    else
      "Never"
    end
  end

  @doc """
  Determines if a user is using social authentication.
  """
  @spec social_user?(Ecto.Schema.t() | nil) :: boolean()
  def social_user?(nil), do: false

  def social_user?(user) do
    user.provider not in [nil, @email_provider]
  end
end
