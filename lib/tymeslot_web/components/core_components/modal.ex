defmodule TymeslotWeb.Components.CoreComponents.Modal do
  @moduledoc "Modal components extracted from CoreComponents."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

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
        <%!-- Form content here --%>
      </.modal>

      # Extra large modal for complex content
      <.modal id="details-modal" show={@show_modal} size={:xlarge}>
        <:header>Meeting Details</:header>
        <%!-- Detailed content here --%>
      </.modal>

      # Full screen modal
      <.modal id="full-modal" show={@show_modal} size={:full}>
        <:header>Full Screen View</:header>
        <%!-- Full screen content here --%>
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}, doc: "JS command executed when the modal is dismissed"

  attr :size, :atom,
    default: :medium,
    values: [:xsmall, :small, :medium, :large, :xlarge, :full]

  attr :aria_label, :string,
    default: nil,
    doc: "Accessible name for the dialog when no :header slot is rendered"

  slot :header, required: false
  slot :inner_block, required: true
  slot :footer, required: false

  @spec modal(map()) :: Phoenix.LiveView.Rendered.t()
  def modal(assigns) do
    assigns = assign(assigns, :dialog_label_attrs, dialog_label_attrs(assigns))

    ~H"""
    <div
      id={@id}
      class="modal-overlay"
      style={if @show, do: "display: flex;", else: "display: none;"}
      phx-window-keydown={@on_cancel}
      phx-key="escape"
      phx-hook="ModalFocusTrap"
    >
      <div class="modal-container p-6">
        <div
          id={"#{@id}-content"}
          class={["modal-content bg-white rounded-[2.5rem] shadow-2xl border-2 border-tymeslot-50 relative overflow-hidden", modal_size_class(@size)]}
          role="dialog"
          aria-modal="true"
          {@dialog_label_attrs}
          tabindex="-1"
          phx-click-away={if @show, do: @on_cancel}
        >
          <%!-- Header --%>
          <%= if @header != [] do %>
            <div class="modal-header px-8 py-6 border-b-2 border-tymeslot-50 flex items-center justify-between">
              <h3
                id={"#{@id}-title"}
                class="modal-title text-2xl font-black text-tymeslot-900 tracking-tight"
              >
                {render_slot(@header)}
              </h3>
              <button
                type="button"
                class="w-10 h-10 rounded-xl bg-tymeslot-50 text-tymeslot-400 hover:bg-red-50 hover:text-red-500 transition-all flex items-center justify-center"
                aria-label={dgettext("common", "Close modal")}
                phx-click={@on_cancel}
              >
                <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2.5"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>
          <% end %>
          
    <%!-- Body --%>
          <div class="modal-body p-8">
            {render_slot(@inner_block)}
          </div>
          
    <%!-- Footer --%>
          <%= if @footer != [] do %>
            <div class="modal-footer px-8 py-6 bg-tymeslot-50/50 border-t-2 border-tymeslot-50">
              {render_slot(@footer)}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Prefer aria-labelledby (pointing at the rendered header slot); fall back to
  # the caller-supplied aria-label when there is no header to label the dialog.
  defp dialog_label_attrs(%{header: header, id: id}) when header != [] do
    %{"aria-labelledby" => "#{id}-title"}
  end

  defp dialog_label_attrs(%{aria_label: aria_label}) do
    %{"aria-label" => aria_label}
  end

  # Helper function for modal size classes
  defp modal_size_class(:xsmall), do: "modal-content--xsmall"
  defp modal_size_class(:small), do: "modal-content--small"
  defp modal_size_class(:medium), do: "modal-content--medium"
  defp modal_size_class(:large), do: "modal-content--large"
  defp modal_size_class(:xlarge), do: "modal-content--xlarge"
  defp modal_size_class(:full), do: "modal-content--full"
  defp modal_size_class(_other), do: "modal-content--medium"
end
