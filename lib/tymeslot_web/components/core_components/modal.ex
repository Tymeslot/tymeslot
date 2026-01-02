defmodule TymeslotWeb.Components.CoreComponents.Modal do
  @moduledoc "Modal components extracted from CoreComponents."
  use Phoenix.Component

  # Phoenix modules
  alias Phoenix.LiveView.JS

  # ========== MODAL ==========

  @doc """
  Renders a modal dialog with glassmorphism styling.

  ## Examples

      # Default medium size
      <.modal id="confirm-modal" show={@show_modal}>
        <:header>Are you sure?</:header>
        This action cannot be undone.
        <:footer>
          <.action_button variant={:secondary} phx-click={JS.hide(to: "#confirm-modal")}>
            Cancel
          </.action_button>
          <.action_button variant={:danger} phx-click="delete">
            Delete
          </.action_button>
        </:footer>
      </.modal>

      # Small modal
      <.modal id="small-modal" show={@show_modal} size={:small}>
        <:header>Quick Note</:header>
        Your changes have been saved.
      </.modal>

      # Large modal for forms
      <.modal id="form-modal" show={@show_modal} size={:large}>
        <:header>Edit Profile</:header>
        <!-- Form content here -->
      </.modal>

      # Extra large modal for complex content
      <.modal id="details-modal" show={@show_modal} size={:xlarge}>
        <:header>Meeting Details</:header>
        <!-- Detailed content here -->
      </.modal>

      # Full screen modal
      <.modal id="full-modal" show={@show_modal} size={:full}>
        <:header>Full Screen View</:header>
        <!-- Full screen content here -->
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :size, :atom, default: :medium, values: [:small, :medium, :large, :xlarge, :full]

  slot :header, required: false
  slot :inner_block, required: true
  slot :footer, required: false
  @spec modal(map()) :: Phoenix.LiveView.Rendered.t()
  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class="modal-overlay"
      style={if @show, do: "display: flex;", else: "display: none;"}
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div class="modal-container">
        <div id={"#{@id}-content"} class={["modal-content", modal_size_class(@size)]}>
          <!-- Header -->
          <%= if @header != [] do %>
            <div class="modal-header">
              <h3 class="modal-title">
                {render_slot(@header)}
              </h3>
              <button
                type="button"
                class="modal-close-button"
                aria-label="Close modal"
                phx-click={@on_cancel}
              >
                <svg class="modal-close-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>
          <% end %>
          
    <!-- Body -->
          <div class="modal-body">
            {render_slot(@inner_block)}
          </div>
          
    <!-- Footer -->
          <%= if @footer != [] do %>
            <div class="modal-footer">
              {render_slot(@footer)}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Helper function for modal size classes
  defp modal_size_class(:small), do: "modal-content--small"
  defp modal_size_class(:medium), do: "modal-content--medium"
  defp modal_size_class(:large), do: "modal-content--large"
  defp modal_size_class(:xlarge), do: "modal-content--xlarge"
  defp modal_size_class(:full), do: "modal-content--full"
  defp modal_size_class(_), do: "modal-content--medium"
end
