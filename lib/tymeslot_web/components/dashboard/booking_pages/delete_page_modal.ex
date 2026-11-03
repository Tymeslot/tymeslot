defmodule TymeslotWeb.Components.Dashboard.BookingPages.DeletePageModal do
  @moduledoc """
  Modal for confirming the deletion of a booking page. It says what happens
  to everything that leads to the page: its address and embeds lead to the
  main page, its bookings keep working in the main page's look, and the
  meeting types listed nowhere else become unlisted.
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
    * `main_address` - The main page's address, without the leading slash (required)
    * `only_listed_here` - Names of the meeting types this page alone lists
      (`Tymeslot.BookingPages.only_listed_on/1`)
    * `on_cancel` - JS command to execute when cancelling (required)
    * `on_confirm` - JS command to execute when confirming deletion (required)
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :address, :string, required: true
  attr :main_address, :string, default: nil, doc: "nil while the profile has no username"
  attr :only_listed_here, :list, default: []
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec delete_page_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_page_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_booking_pages", "Delete booking page")}
      confirm_label={dgettext("dashboard_booking_pages", "Delete page")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <div class="space-y-3">
        <p>
          {dgettext(
            "dashboard_booking_pages",
            "Delete %{address}? Its address will lead to your main page at %{main}, and websites that embed it will show your main page.",
            address: "/#{@address}",
            main: "/#{@main_address}"
          )}
        </p>
        <div :if={@only_listed_here != []} data-testid="delete-page-unlisted-types">
          <p>
            {dngettext(
              "dashboard_booking_pages",
              "This meeting type is listed only on this page and will be unlisted everywhere, bookable only by its direct link:",
              "These meeting types are listed only on this page and will be unlisted everywhere, bookable only by their direct links:",
              length(@only_listed_here)
            )}
          </p>
          <ul class="mt-2 list-disc pl-5 font-semibold">
            <li :for={name <- @only_listed_here}>{name}</li>
          </ul>
        </div>
        <p>
          {dgettext(
            "dashboard_booking_pages",
            "Bookings made through it keep working and show your main page's look. Its colours and uploaded backgrounds are removed."
          )}
        </p>
      </div>
    </Modal.confirm_modal>
    """
  end
end
