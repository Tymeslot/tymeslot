defmodule TymeslotWeb.Shared.Auth.IconComponents do
  @moduledoc """
  Icon components used across authentication flows.
  """

  use TymeslotWeb, :html

  @spec email_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def email_icon(assigns) do
    ~H"""
    <svg
      class="h-5 w-5 text-gray-400 group-hover:text-purple-600 transition-colors duration-300"
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z" />
      <path d="M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
    </svg>
    """
  end

  @spec success_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def success_icon(assigns) do
    ~H"""
    <svg
      class="mx-auto h-12 w-12 sm:h-14 sm:w-14 text-green-500"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
      />
    </svg>
    """
  end

  @spec email_verification_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def email_verification_icon(assigns) do
    ~H"""
    <svg
      class="w-7 h-7 sm:w-8 sm:h-8 md:w-10 md:h-10 text-teal-50"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      aria-hidden="true"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2.5"
        d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
      />
    </svg>
    """
  end
end
