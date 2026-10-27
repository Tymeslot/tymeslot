defmodule TymeslotWeb.AccountLive.Helpers do
  @moduledoc """
  Helper functions for account management.
  Provides state management and formatting utilities.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Auth
  alias TymeslotWeb.Helpers.LocaleFormat

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
    |> assign(:show_delete_modal, false)
    |> assign(:delete_errors, %{})
    |> assign(:deletion_date, "")
    |> assign(:deletion_grace_days, Auth.account_deletion_grace_days())
    |> assign(
      :deletion_confirmation,
      Auth.deletion_confirmation_method(socket.assigns.current_user)
    )
    |> assign(:deletion_feedback_options, deletion_feedback_options())
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
      locale = Gettext.get_locale(TymeslotWeb.Gettext)
      LocaleFormat.format_date(user.updated_at, locale)
    else
      dgettext("account", "Never")
    end
  end

  @doc "The reason picker's options, or `[]` when feedback is not collected."
  @spec deletion_feedback_options() :: [{String.t(), String.t()}]
  def deletion_feedback_options do
    if Auth.collect_deletion_feedback?(),
      do: Enum.map(Auth.deletion_feedback_reasons(), &{feedback_label(&1), &1}),
      else: []
  end

  defp feedback_label("too_expensive"), do: dgettext("account", "It costs too much")

  defp feedback_label("missing_features"),
    do: dgettext("account", "It is missing something I need")

  defp feedback_label("hard_to_use"), do: dgettext("account", "It is hard to use")
  defp feedback_label("switched_tool"), do: dgettext("account", "I switched to another tool")
  defp feedback_label("no_longer_needed"), do: dgettext("account", "I no longer need it")
  defp feedback_label("technical_problems"), do: dgettext("account", "Something kept going wrong")
  defp feedback_label("other"), do: dgettext("account", "Another reason")

  @spec social_user?(Ecto.Schema.t() | nil) :: boolean()
  defp social_user?(nil), do: false

  defp social_user?(user) do
    user.provider not in [nil, @email_provider]
  end
end
