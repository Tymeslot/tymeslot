defmodule TymeslotWeb.Shared.Auth.IconComponents do
  @moduledoc """
  Icon components used across authentication flows.
  """

  use TymeslotWeb, :html

  @spec email_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def email_icon(assigns) do
    ~H"""
    <.icon
      name="hero-envelope-mini"
      class="h-5 w-5 text-tymeslot-400 group-hover:text-purple-600 transition-colors duration-300"
    />
    """
  end

  @spec success_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def success_icon(assigns) do
    ~H"""
    <.icon name="hero-check-circle" class="mx-auto h-12 w-12 sm:h-14 sm:w-14 text-green-500" />
    """
  end

  @spec email_verification_icon(map()) :: Phoenix.LiveView.Rendered.t()
  def email_verification_icon(assigns) do
    ~H"""
    <.icon
      name="hero-envelope"
      class="w-7 h-7 sm:w-8 sm:h-8 md:w-10 md:h-10 text-turquoise-50"
    />
    """
  end
end
