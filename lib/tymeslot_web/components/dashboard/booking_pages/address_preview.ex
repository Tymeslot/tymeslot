defmodule TymeslotWeb.Components.Dashboard.BookingPages.AddressPreview do
  @moduledoc """
  A booking page's whole link as guests see it, without the scheme
  (`tymeslot.example/jane/coaching`), its address in bold. Shown under an
  address field so the host sees the link they are completing as they type.
  """

  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents.Icons, only: [icon: 1]

  alias Tymeslot.Utils.UrlBuilder

  attr :id, :string, required: true
  attr :username, :string, required: true
  attr :slug, :string, default: nil

  @spec address_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def address_preview(assigns) do
    assigns = assign(assigns, :prefix, prefix(assigns.username))

    ~H"""
    <span id={@id} class="flex items-start gap-1 break-all">
      <.icon name="hero-link-mini" class="w-3.5 h-3.5 mt-px shrink-0" />
      <span>{@prefix}<span class="font-bold text-tymeslot-700">{@slug}</span></span>
    </span>
    """
  end

  defp prefix(username),
    do: String.replace(UrlBuilder.base_url(), ~r{^https?://}, "") <> "/#{username}/"
end
