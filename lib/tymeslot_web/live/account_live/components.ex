defmodule TymeslotWeb.AccountLive.Components do
  @moduledoc """
  UI components for the Account Settings LiveView.
  Provides reusable components for email and password management.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.AccountLive.Forms
  import TymeslotWeb.Components.CoreComponents.Icons
  import TymeslotWeb.Components.FlagHelpers
  alias TymeslotWeb.AccountLive.Helpers

  @doc """
  Renders the security header with icon and title.
  """
  # No assigns used in this component - purely static HTML
  @spec security_header(map) :: Phoenix.LiveView.Rendered.t()
  def security_header(assigns) do
    ~H"""
    <div class="flex items-center mb-8">
      <div class="text-tymeslot-600 mr-3">
        <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.031 9-11.622 0-1.042-.133-2.052-.382-3.016z"
          />
        </svg>
      </div>
      <h1 class="text-3xl font-bold text-tymeslot-800">{dgettext("account", "Account Security")}</h1>
    </div>
    """
  end

  @doc """
  Renders the email settings card with form.
  """
  attr :current_user, :map, required: true
  attr :is_social_user, :boolean, required: true
  attr :show_email_form, :boolean, required: true
  attr :email_form_errors, :map, required: true
  attr :saving_email, :boolean, required: true

  @spec email_card(map) :: Phoenix.LiveView.Rendered.t()
  def email_card(assigns) do
    ~H"""
    <div class={card_classes(@is_social_user)}>
      <.card_header
        title={dgettext("account", "Email Address")}
        current_value={@current_user.email}
        pending_email={@current_user.pending_email}
        is_social={@is_social_user}
        provider={@current_user.provider}
        show_form={@show_email_form}
        toggle_event="toggle_email_form"
        button_text={
          if @show_email_form,
            do: dgettext("account", "Cancel"),
            else: dgettext("account", "Change Email")
        }
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
  attr :current_user, :map, required: true
  attr :is_social_user, :boolean, required: true
  attr :show_password_form, :boolean, required: true
  attr :password_form_errors, :map, required: true
  attr :saving_password, :boolean, required: true

  @spec password_card(map) :: Phoenix.LiveView.Rendered.t()
  def password_card(assigns) do
    ~H"""
    <div class={card_classes(@is_social_user)}>
      <.card_header
        title={dgettext("account", "Password")}
        is_social={@is_social_user}
        provider={@current_user.provider}
        show_form={@show_password_form}
        toggle_event="toggle_password_form"
        button_text={
          if @show_password_form,
            do: dgettext("account", "Cancel"),
            else: dgettext("account", "Change Password")
        }
        subtitle={
          if @is_social_user do
            dgettext("account", "Authentication is managed through %{provider}",
              provider: String.capitalize(@current_user.provider)
            )
          else
            dgettext("account", "Last changed: %{last_changed}",
              last_changed: Helpers.format_last_password_change(@current_user)
            )
          end
        }
        description={
          if @is_social_user do
            dgettext("account", "Password authentication is not available for social login accounts")
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
  Renders the interface-language preference card as a row of flag buttons. Each
  button auto-saves the chosen locale on click (`phx-click="change_language"`)
  and immediately highlights as active; the Automatic button clears the
  preference so the dashboard follows the browser/session locale.
  """
  attr :current_user, :map, required: true
  attr :supported_locales, :list, required: true

  @spec language_card(map) :: Phoenix.LiveView.Rendered.t()
  def language_card(assigns) do
    ~H"""
    <div class={card_classes(false)}>
      <div class="mb-4">
        <h3 class="text-lg font-medium text-tymeslot-800">{dgettext("account", "Language")}</h3>
        <p class="text-sm text-tymeslot-600 mt-1">
          {dgettext(
            "account",
            "Choose the language for your dashboard. Automatic follows your browser's preference."
          )}
        </p>
      </div>
      <div
        class="flex flex-wrap items-center gap-3"
        role="group"
        aria-label={dgettext("account", "Interface language")}
      >
        <button
          type="button"
          phx-click="change_language"
          phx-value-locale=""
          aria-pressed={is_nil(@current_user.locale)}
          title={
            dgettext("account", "Follow your browser's language setting instead of a fixed choice.")
          }
          class={[
            "btn-tag-selector btn-tag-selector-primary inline-flex items-center gap-2",
            is_nil(@current_user.locale) && "btn-tag-selector-primary--active"
          ]}
        >
          <.icon name="hero-globe-alt" class="w-4 h-4" />
          {dgettext("account", "Automatic")}
        </button>
        <button
          :for={locale <- @supported_locales}
          type="button"
          phx-click="change_language"
          phx-value-locale={locale.code}
          aria-pressed={@current_user.locale == locale.code}
          class={[
            "btn-tag-selector btn-tag-selector-primary inline-flex items-center gap-2",
            @current_user.locale == locale.code && "btn-tag-selector-primary--active"
          ]}
        >
          <.locale_flag locale={locale.code} class="w-5 h-4" />
          {locale.name}
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a card header with title, current value, and action button.
  """
  attr :title, :string, required: true
  attr :is_social, :boolean, required: true
  attr :provider, :string, default: nil
  attr :toggle_event, :string, required: true
  attr :button_text, :string, required: true
  attr :current_value, :string, default: nil
  attr :pending_email, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :description, :string, default: nil
  attr :show_form, :boolean, required: true

  @spec card_header(map) :: Phoenix.LiveView.Rendered.t()
  def card_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <div>
        <h3 class="text-lg font-medium text-tymeslot-800">{@title}</h3>
        <%= if @current_value do %>
          <p class="text-sm text-tymeslot-600 mt-1">
            {dgettext("account", "Current email:")}
            <span class="font-medium text-tymeslot-800">{@current_value}</span>
          </p>
        <% end %>
        <%= if @pending_email do %>
          <p class="text-sm text-amber-600 mt-1">
            {dgettext("account", "Pending change to:")}
            <span class="font-medium">{@pending_email}</span>
          </p>
        <% end %>
        <%= if @subtitle do %>
          <p class="text-sm text-tymeslot-600 mt-1">{@subtitle}</p>
        <% end %>
        <%= if @description do %>
          <p class="text-sm text-tymeslot-500 mt-2">{@description}</p>
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
  attr :toggle_event, :string, required: true
  attr :button_text, :string, required: true
  attr :is_social, :boolean, required: true
  attr :provider, :string, default: nil

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
  attr :provider, :string, required: true

  @spec social_tooltip(map) :: Phoenix.LiveView.Rendered.t()
  def social_tooltip(assigns) do
    ~H"""
    <div class="absolute bottom-full right-0 mb-2 hidden group-hover:block z-10">
      <div class="bg-tymeslot-900 text-white text-xs rounded-lg py-2 px-3 whitespace-nowrap">
        {dgettext("account", "Managed by %{provider}", provider: String.capitalize(@provider))}
        <div class="absolute top-full right-4 w-0 h-0 border-l-[6px] border-l-transparent border-t-[6px] border-t-tymeslot-900 border-r-[6px] border-r-transparent">
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a notice for pending email change.
  """
  attr :pending_email, :string, required: true
  attr :email_change_sent_at, :any, default: nil

  @spec pending_email_notice(map) :: Phoenix.LiveView.Rendered.t()
  def pending_email_notice(assigns) do
    ~H"""
    <div class="bg-amber-50 border border-amber-200 rounded-lg p-4 mb-4">
      <div class="flex items-start">
        <div class="shrink-0">
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
            {dgettext("account", "Email Change Pending")}
          </h3>
          <div class="mt-2 text-sm text-amber-700">
            <p>
              {dgettext("account", "A verification email has been sent to")}
              <strong>{@pending_email}</strong>
            </p>
            <%= if @email_change_sent_at do %>
              <p class="mt-1 text-xs text-amber-600">
                {dgettext("account", "Sent %{time}",
                  time: format_relative_time(@email_change_sent_at)
                )}
              </p>
            <% end %>
          </div>
          <div class="mt-3">
            <button
              phx-click="cancel_email_change"
              class="text-sm font-medium text-amber-600 hover:text-amber-500"
            >
              {dgettext("account", "Cancel email change")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Private helper functions
  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime)

    cond do
      diff < 60 -> dgettext("account", "just now")
      diff < 3600 -> minutes_ago(div(diff, 60))
      diff < 86_400 -> hours_ago(div(diff, 3600))
      true -> days_ago(div(diff, 86_400))
    end
  end

  defp minutes_ago(count) do
    dngettext("account", "%{count} minute ago", "%{count} minutes ago", count, count: count)
  end

  defp hours_ago(count) do
    dngettext("account", "%{count} hour ago", "%{count} hours ago", count, count: count)
  end

  defp days_ago(count) do
    dngettext("account", "%{count} day ago", "%{count} days ago", count, count: count)
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
