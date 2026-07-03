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
            "w-10 h-10 rounded-xl flex items-center justify-center border",
            if(@confirm_variant == :danger, do: "bg-red-50 border-red-100", else: "bg-turquoise-50 border-turquoise-100")
          ]}>
            <svg class={["w-6 h-6", if(@confirm_variant == :danger, do: "text-red-500", else: "text-turquoise-600")]} fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z" />
            </svg>
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
