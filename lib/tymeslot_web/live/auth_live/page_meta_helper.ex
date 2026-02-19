defmodule TymeslotWeb.AuthLive.PageMetaHelper do
  @moduledoc """
  Maps authentication states to page titles and meta descriptions.

  Only public-facing, indexable auth pages receive titles and descriptions.
  Transient and OAuth-flow states (complete_registration, verify_email,
  reset_password_sent, password_reset_success, invalid_token) are excluded
  since they are not indexed.
  """

  import Phoenix.Component, only: [assign: 3]

  @doc """
  Assigns page_title and meta_description to the socket based on current_state.
  Only assigns values when both are defined for the state.
  """
  @spec assign_page_meta(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_page_meta(socket) do
    case page_meta_for_state(socket.assigns.current_state) do
      {title, description} ->
        socket
        |> assign(:page_title, title)
        |> assign(:meta_description, description)

      nil ->
        socket
    end
  end

  defp page_meta_for_state(:login),
    do:
      {"Log In",
       "Sign in to your Tymeslot account to manage scheduling links, availability, and bookings."}

  defp page_meta_for_state(:signup),
    do:
      {"Create an Account",
       "Create a Tymeslot account and start sharing your availability in minutes. No credit card required."}

  defp page_meta_for_state(:reset_password),
    do:
      {"Reset Password",
       "Enter your email to receive a password reset link for your Tymeslot account."}

  defp page_meta_for_state(:reset_password_form),
    do: {"Choose a New Password", "Choose a strong new password for your Tymeslot account."}

  defp page_meta_for_state(_state), do: nil
end
