defmodule TymeslotWeb.Components.CoreComponents.Modal do
  @moduledoc "Modal components extracted from CoreComponents."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  # Phoenix modules
  alias Phoenix.LiveView.JS

  # Application modules
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Icons

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

      # With a line of explanation under the title
      <.modal id="venue-modal" show={@show_modal}>
        <:header>Add location</:header>
        <:subtitle>A place you meet people.</:subtitle>
        <%!-- Form content here --%>
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

  slot :subtitle,
    required: false,
    doc: "A line of explanation under the header; rendered only with a :header"

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
          class={
            [
              # Scrolling and the height cap belong to `.modal-content` in
              # modal.css; an `overflow-hidden` here would win over it and cut a
              # tall dialog off again.
              "modal-content bg-white rounded-[2.5rem] shadow-2xl border-2 border-tymeslot-50 relative",
              modal_size_class(@size)
            ]
          }
          role="dialog"
          aria-modal="true"
          {@dialog_label_attrs}
          tabindex="-1"
          phx-click-away={if @show, do: @on_cancel}
        >
          <%!-- Header --%>
          <%= if @header != [] do %>
            <div class={[
              "modal-header px-8 py-6 border-b-2 border-tymeslot-50 flex justify-between gap-4",
              if(@subtitle == [], do: "items-center", else: "items-start")
            ]}>
              <div class="min-w-0">
                <h3
                  id={"#{@id}-title"}
                  class="modal-title text-2xl font-black text-tymeslot-900 tracking-tight"
                >
                  {render_slot(@header)}
                </h3>
                <p
                  :if={@subtitle != []}
                  id={"#{@id}-subtitle"}
                  class="mt-1 text-token-sm font-medium text-tymeslot-500"
                >
                  {render_slot(@subtitle)}
                </p>
              </div>
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
          <%!-- `scrollable` is the app's own scrollbar styling, shared with
                the body and the other scrolling panels. --%>
          <div class="modal-body scrollable p-8">
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

  @doc """
  Renders a confirmation dialog on top of `modal/1`: an icon tile and title in
  the header, the caller's explanation in the body, and a fixed footer of
  Cancel then Confirm.

  Every "are you sure?" in the dashboard goes through this, so destructive
  questions look and behave the same everywhere. The owning module keeps its
  own wording and events; this owns the layout.

  Confirm either pushes `on_confirm` or, with `confirm_form`, submits the form
  of that id rendered in the body. Attributes not declared here (`phx-target`,
  `phx-value-*`, `phx-disable-with`, `data-testid`) land on the Confirm button.
  Where the answer is a choice between several actions, the `:actions` slot
  replaces the single Confirm button; Cancel always stays first.

  ## Examples

      <.confirm_modal
        id="delete-thing-modal"
        show={@show_delete}
        title={dgettext("dashboard_common", "Delete thing")}
        confirm_label={dgettext("dashboard_common", "Delete thing")}
        on_cancel={JS.push("hide_delete", target: @myself)}
        on_confirm={JS.push("confirm_delete", target: @myself)}
      >
        <p>{dgettext("dashboard_common", "Delete %{name}?", name: @thing.name)}</p>
        <:extra>
          <.info_box variant={:warning}>...</.info_box>
        </:extra>
      </.confirm_modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, required: true
  attr :on_cancel, JS, default: %JS{}, doc: "pushed by Cancel, Escape and a click outside"

  attr :on_confirm, :any,
    default: nil,
    doc: "event name or JS pushed by Confirm; leave unset when `confirm_form` submits"

  attr :confirm_form, :string,
    default: nil,
    doc: "id of a form in the body; Confirm becomes its submit button"

  attr :confirm_label, :string, default: nil, doc: "defaults to \"Confirm\""
  attr :cancel_label, :string, default: nil, doc: "defaults to \"Cancel\""
  attr :confirm_variant, :atom, default: :danger, values: [:danger, :primary]
  attr :icon, :string, default: "hero-exclamation-triangle", doc: "a `hero-…` icon name"
  attr :size, :atom, default: :medium, values: [:small, :medium]
  attr :loading, :boolean, default: false, doc: "shows Confirm's spinner and locks both buttons"
  attr :loading_label, :string, default: nil
  attr :confirm_disabled, :boolean, default: false
  attr :rest, :global, doc: "extra attributes for the Confirm button"

  slot :inner_block, required: true
  slot :extra, doc: "secondary content under the body, such as an info box or a checkbox"
  slot :actions, doc: "replaces the Confirm button when the answer is a choice"

  @spec confirm_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_modal(assigns) do
    ~H"""
    <.modal id={@id} show={@show} on_cancel={@on_cancel} size={@size}>
      <:header>
        <span class="flex items-center gap-3">
          <span class={[
            "w-10 h-10 shrink-0 rounded-token-xl flex items-center justify-center border",
            confirm_tile_class(@confirm_variant)
          ]}>
            <Icons.icon name={@icon} class="w-6 h-6" />
          </span>
          <span>{@title}</span>
        </span>
      </:header>

      <div class="space-y-4 text-tymeslot-600 font-medium leading-relaxed">
        {render_slot(@inner_block)}
        <div :if={@extra != []} class="space-y-3">
          {render_slot(@extra)}
        </div>
      </div>

      <:footer>
        <div class="flex flex-wrap justify-end gap-3">
          <Buttons.action_button variant={:secondary} disabled={@loading} phx-click={@on_cancel}>
            {@cancel_label || dgettext("common", "Cancel")}
          </Buttons.action_button>
          <%= if @actions != [] do %>
            {render_slot(@actions)}
          <% else %>
            <Buttons.loading_button
              variant={@confirm_variant}
              type={if @confirm_form, do: "submit", else: "button"}
              form={@confirm_form}
              loading={@loading}
              loading_text={@loading_label}
              disabled={@confirm_disabled}
              phx-click={@on_confirm}
              {@rest}
            >
              {@confirm_label || dgettext("common", "Confirm")}
            </Buttons.loading_button>
          <% end %>
        </div>
      </:footer>
    </.modal>
    """
  end

  defp confirm_tile_class(:danger), do: "bg-red-50 border-red-100 text-red-500"
  defp confirm_tile_class(:primary), do: "bg-turquoise-50 border-turquoise-100 text-turquoise-600"

  # Prefer aria-labelledby (pointing at the rendered header slot); fall back to
  # the caller-supplied aria-label when there is no header to label the dialog.
  defp dialog_label_attrs(%{header: header, subtitle: subtitle, id: id}) when header != [] do
    attrs = %{"aria-labelledby" => "#{id}-title"}
    if subtitle == [], do: attrs, else: Map.put(attrs, "aria-describedby", "#{id}-subtitle")
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
