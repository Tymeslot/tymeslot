defmodule TymeslotWeb.Components.Dashboard.BookingPages.DeletePageModal do
  @moduledoc """
  Modal for confirming the deletion of a booking page. Its bookings keep
  working in the main page's look, so the confirmation says so.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  @doc """
  Renders a delete booking page confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `address` - The page's address, without the leading slash (required)
    * `on_cancel` - JS command to execute when cancelling (required)
    * `on_confirm` - JS command to execute when confirming deletion (required)
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :address, :string, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec delete_page_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_page_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_appearance", "Delete booking page")}
      confirm_label={dgettext("dashboard_appearance", "Delete page")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <p>
        {dgettext(
          "dashboard_appearance",
          "Delete %{address}? Bookings made through it keep working and show your main page's look. Its colours and uploaded backgrounds are removed.",
          address: "/" <> @address
        )}
      </p>
    </Modal.confirm_modal>
    """
  end
end
