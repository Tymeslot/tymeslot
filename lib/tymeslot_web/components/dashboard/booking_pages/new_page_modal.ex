defmodule TymeslotWeb.Components.Dashboard.BookingPages.NewPageModal do
  @moduledoc """
  Modal for creating a booking page: its name and address.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Components.CoreComponents

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages.BookingPageSchema
  alias TymeslotWeb.Components.CoreComponents.Modal

  @doc """
  Renders the new booking page modal.

  ## Attributes

    * `show` - Boolean to show/hide the modal (required)
    * `form` - The new page's form (required)
    * `target` - The component that owns the form's events (required)
    * `on_cancel` - JS command to execute when cancelling (required)

  Its form sends `validate_new_page` and `create_page`, and its cancel
  button `hide_new_page`, to `target`.
  """
  attr :show, :boolean, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :target, :any, required: true
  attr :on_cancel, JS, required: true

  @spec new_page_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def new_page_modal(assigns) do
    ~H"""
    <Modal.modal id="new-booking-page-modal" show={@show} on_cancel={@on_cancel}>
      <:header>{dgettext("dashboard_appearance", "New booking page")}</:header>

      <.form
        for={@form}
        id="new-booking-page-form"
        phx-change="validate_new_page"
        phx-submit="create_page"
        phx-target={@target}
        class="space-y-6"
      >
        <.input
          field={@form[:name]}
          label={dgettext("dashboard_appearance", "Page name")}
          maxlength={BookingPageSchema.name_max_length()}
        />
        <.input field={@form[:slug]} label={dgettext("dashboard_appearance", "Address")} />
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_appearance",
            "The page starts with your main page's theme and colours, its own texts switched off, and no meeting types."
          )}
        </p>
        <div class="flex justify-end gap-3">
          <.action_button
            type="button"
            variant={:secondary}
            phx-click="hide_new_page"
            phx-target={@target}
          >
            {dgettext("dashboard_appearance", "Cancel")}
          </.action_button>
          <.action_button type="submit">
            {dgettext("dashboard_appearance", "Create page")}
          </.action_button>
        </div>
      </.form>
    </Modal.modal>
    """
  end
end
