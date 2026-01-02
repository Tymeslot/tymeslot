defmodule TymeslotWeb.Shared.PasswordToggleButtonComponent do
  @moduledoc """
  Password visibility toggle button component.

  Provides a button that toggles password field visibility
  between masked and plain text display.
  """

  use Phoenix.Component

  @doc """
  Renders a password visibility toggle button for password fields.
  """
  @spec password_toggle_button(map()) :: Phoenix.LiveView.Rendered.t()
  def password_toggle_button(assigns) do
    assigns = assign_new(assigns, :class, fn -> "" end)

    ~H"""
    <button
      type="button"
      id={@id}
      onclick="togglePasswordVisibility(this)"
      class={"absolute top-1/2 -translate-y-1/2 right-2 sm:right-3 text-gray-400 hover:text-purple-600 transition duration-300 ease-in-out focus:outline-none p-1 sm:p-0 bg-transparent border-none flex items-center justify-center #{@class}"}
      aria-label="Toggle password visibility"
      tabindex="-1"
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="h-4 w-4 sm:h-5 sm:w-5 eye-open"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
        />
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
        />
      </svg>
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="h-4 w-4 sm:h-5 sm:w-5 eye-closed hidden"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"
        />
      </svg>
    </button>
    """
  end
end
