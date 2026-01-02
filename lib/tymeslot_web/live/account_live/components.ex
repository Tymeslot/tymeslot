defmodule TymeslotWeb.AccountLive.Components do
  @moduledoc """
  UI components for the Account Settings LiveView.
  Provides reusable components for email and password management.
  """
  use Phoenix.Component

  import TymeslotWeb.AccountLive.Forms
  alias TymeslotWeb.AccountLive.Helpers

  @doc """
  Renders the security header with icon and title.
  """
  @spec security_header(map) :: Phoenix.LiveView.Rendered.t()
  def security_header(assigns) do
    ~H"""
    <div class="flex items-center mb-8">
      <div class="text-gray-600 mr-3">
        <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.031 9-11.622 0-1.042-.133-2.052-.382-3.016z"
          />
        </svg>
      </div>
      <h1 class="text-3xl font-bold text-gray-800">Account Security</h1>
    </div>
    """
  end

  @doc """
  Renders the email settings card with form.
  """
  @spec email_card(map) :: Phoenix.LiveView.Rendered.t()
  def email_card(assigns) do
    ~H"""
    <div class={card_classes(@is_social_user)}>
      <.card_header
        title="Email Address"
        current_value={@current_user.email}
        pending_email={@current_user.pending_email}
        is_social={@is_social_user}
        provider={@current_user.provider}
        show_form={@show_email_form}
        toggle_event="toggle_email_form"
        button_text={if @show_email_form, do: "Cancel", else: "Change Email"}
      />

      <%= if @current_user.pending_email do %>
        <.pending_email_notice
          pending_email={@current_user.pending_email}
          email_change_sent_at={@current_user.email_change_sent_at}
        />
      <% end %>

      <%= if @show_email_form do %>
        <.email_form errors={@email_form_errors} saving={@saving_email} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders the password settings card with form.
  """
  @spec password_card(map) :: Phoenix.LiveView.Rendered.t()
  def password_card(assigns) do
    ~H"""
    <div class={card_classes(@is_social_user)}>
      <.card_header
        title="Password"
        is_social={@is_social_user}
        provider={@current_user.provider}
        show_form={@show_password_form}
        toggle_event="toggle_password_form"
        button_text={if @show_password_form, do: "Cancel", else: "Change Password"}
        subtitle={
          if @is_social_user do
            "Authentication is managed through #{String.capitalize(@current_user.provider)}"
          else
            "Last changed: #{Helpers.format_last_password_change(@current_user)}"
          end
        }
        description={
          if @is_social_user do
            "Password authentication is not available for social login accounts"
          else
            nil
          end
        }
      />

      <%= if @show_password_form do %>
        <.password_form errors={@password_form_errors} saving={@saving_password} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a card header with title, current value, and action button.
  """
  @spec card_header(map) :: Phoenix.LiveView.Rendered.t()
  def card_header(assigns) do
    assigns = assign_new(assigns, :current_value, fn -> nil end)
    assigns = assign_new(assigns, :pending_email, fn -> nil end)
    assigns = assign_new(assigns, :subtitle, fn -> nil end)
    assigns = assign_new(assigns, :description, fn -> nil end)

    ~H"""
    <div class="flex items-center justify-between mb-4">
      <div>
        <h3 class="text-lg font-medium text-gray-800">{@title}</h3>
        <%= if @current_value do %>
          <p class="text-sm text-gray-600 mt-1">
            Current email: <span class="font-medium text-gray-800">{@current_value}</span>
          </p>
        <% end %>
        <%= if @pending_email do %>
          <p class="text-sm text-amber-600 mt-1">
            Pending change to: <span class="font-medium">{@pending_email}</span>
          </p>
        <% end %>
        <%= if @subtitle do %>
          <p class="text-sm text-gray-600 mt-1">{@subtitle}</p>
        <% end %>
        <%= if @is_social && @description do %>
          <p class="text-sm text-gray-500 mt-2">{@description}</p>
        <% end %>
      </div>
      <.action_button
        is_social={@is_social}
        provider={@provider}
        toggle_event={@toggle_event}
        button_text={@button_text}
      />
    </div>
    """
  end

  @doc """
  Renders an action button with optional disabled state and tooltip.
  """
  @spec action_button(map) :: Phoenix.LiveView.Rendered.t()
  def action_button(assigns) do
    ~H"""
    <div class="relative group">
      <button phx-click={@toggle_event} class={button_classes(@is_social)} disabled={@is_social}>
        {@button_text}
      </button>
      <%= if @is_social do %>
        <.social_tooltip provider={@provider} />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a tooltip for social login restrictions.
  """
  @spec social_tooltip(map) :: Phoenix.LiveView.Rendered.t()
  def social_tooltip(assigns) do
    ~H"""
    <div class="absolute bottom-full right-0 mb-2 hidden group-hover:block z-10">
      <div class="bg-gray-900 text-white text-xs rounded-lg py-2 px-3 whitespace-nowrap">
        Managed by {String.capitalize(@provider)}
        <div class="absolute top-full right-4 w-0 h-0 border-l-[6px] border-l-transparent border-t-[6px] border-t-gray-900 border-r-[6px] border-r-transparent">
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a notice for pending email change.
  """
  @spec pending_email_notice(map) :: Phoenix.LiveView.Rendered.t()
  def pending_email_notice(assigns) do
    ~H"""
    <div class="bg-amber-50 border border-amber-200 rounded-lg p-4 mb-4">
      <div class="flex items-start">
        <div class="flex-shrink-0">
          <svg class="h-5 w-5 text-amber-400" fill="currentColor" viewBox="0 0 20 20">
            <path
              fill-rule="evenodd"
              d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <div class="ml-3 flex-1">
          <h3 class="text-sm font-medium text-amber-800">
            Email Change Pending
          </h3>
          <div class="mt-2 text-sm text-amber-700">
            <p>
              A verification email has been sent to <strong>{@pending_email}</strong>
            </p>
            <%= if @email_change_sent_at do %>
              <p class="mt-1 text-xs text-amber-600">
                Sent {format_relative_time(@email_change_sent_at)}
              </p>
            <% end %>
          </div>
          <div class="mt-3">
            <button
              phx-click="cancel_email_change"
              class="text-sm font-medium text-amber-600 hover:text-amber-500"
            >
              Cancel email change
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Private helper functions
  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime)

    cond do
      diff_seconds < 60 -> "just now"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)} minutes ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)} hours ago"
      true -> "#{div(diff_seconds, 86_400)} days ago"
    end
  end

  defp card_classes(is_social) do
    if is_social do
      "card-glass card-glass-disabled"
    else
      "card-glass"
    end
  end

  defp button_classes(is_social) do
    base = ["btn", "btn-sm"]

    if is_social do
      base ++ ["btn-disabled", "opacity-50", "cursor-not-allowed"]
    else
      base ++ ["btn-primary"]
    end
  end
end
