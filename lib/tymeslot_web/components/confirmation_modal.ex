defmodule TymeslotWeb.Components.ConfirmationModal do
  @moduledoc """
  Reusable confirmation modal built on the central `<.modal>` core component.

  Renders a titled warning modal with a cancel/confirm button pair. The confirm
  action and its wording are supplied by the caller; the `:danger` variant is
  used for destructive confirmations.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :on_cancel, JS, default: %JS{}
  attr :on_confirm, :any, required: true
  attr :confirm_text, :string, default: "Confirm"
  attr :confirm_variant, :atom, default: :danger
  attr :confirm_disable_with, :string, default: "Processing..."

  @spec confirmation_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirmation_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-3">
          <div class={[
            "w-10 h-10 rounded-token-xl flex items-center justify-center border",
            if(@confirm_variant == :danger, do: "bg-red-50 border-red-100", else: "bg-turquoise-50 border-turquoise-100")
          ]}>
            <CoreComponents.icon
              name="hero-exclamation-triangle"
              class={"w-6 h-6 " <> if(@confirm_variant == :danger, do: "text-red-500", else: "text-turquoise-600")}
            />
          </div>
          <span class="text-2xl font-black text-tymeslot-900 tracking-tight">{@title}</span>
        </div>
      </:header>

      <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">{@message}</p>

      <:footer>
        <div class="flex gap-4">
          <button
            type="button"
            phx-click={@on_cancel}
            class="btn-secondary flex-1 py-4"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click={@on_confirm}
            phx-disable-with={@confirm_disable_with}
            class={[
              "flex-1 py-4",
              if(@confirm_variant == :danger, do: "btn-danger", else: "btn-primary")
            ]}
          >
            {@confirm_text}
          </button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
