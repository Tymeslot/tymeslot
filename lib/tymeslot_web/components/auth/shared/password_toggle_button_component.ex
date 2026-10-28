defmodule TymeslotWeb.Shared.PasswordToggleButtonComponent do
  @moduledoc """
  Password visibility toggle button component.

  Provides a button that toggles password field visibility
  between masked and plain text display.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  @doc """
  Renders a password visibility toggle button for password fields.
  """
  attr :id, :string, required: true
  attr :class, :string, default: ""

  @spec password_toggle_button(map()) :: Phoenix.LiveView.Rendered.t()
  def password_toggle_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-password-toggle-button
      class={"pointer-events-auto absolute top-1/2 -translate-y-1/2 right-2 sm:right-3 text-tymeslot-400 hover:text-purple-600 transition duration-300 ease-in-out focus:outline-hidden p-1 sm:p-0 bg-transparent border-none flex items-center justify-center #{@class}"}
      aria-label={dgettext("auth", "Toggle password visibility")}
      tabindex="-1"
    >
      <.icon name="hero-eye" class="h-4 w-4 sm:h-5 sm:w-5" data-eye-open />
      <.icon name="hero-eye-slash" class="h-4 w-4 sm:h-5 sm:w-5 hidden" data-eye-closed />
    </button>
    """
  end
end
