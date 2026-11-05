defmodule TymeslotWeb.Components.Dashboard.BookingPages.NewPageModal do
  @moduledoc """
  Modal for creating a booking page: its name and address.

  The form mounts only while the modal is shown, so the name field takes the
  focus each time it opens (through `AutoFocus`, which the modal's focus trap
  defers to), and the address field's description is the whole link, completed
  as the address is typed. A field shows
  its errors once the host has used it, or on submit: typing an address does
  not flag the name left empty.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Components.CoreComponents

  alias Phoenix.LiveView.JS
  alias Tymeslot.BookingPages.BookingPageSchema
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Components.Dashboard.BookingPages.AddressPreview

  @doc """
  Renders the new booking page modal.

  ## Attributes

    * `show` - Boolean to show/hide the modal (required)
    * `form` - The new page's form (required)
    * `target` - The component that owns the form's events (required)
    * `username` - The host's username, which the page's link starts with (required)
    * `on_cancel` - JS command to execute when cancelling (required)

  Its form sends `validate_new_page` and `create_page`, and its cancel
  button `hide_new_page`, to `target`.
  """
  attr :show, :boolean, required: true
  attr :form, Phoenix.HTML.Form, required: true
  attr :target, :any, required: true
  attr :username, :string, required: true
  attr :on_cancel, JS, required: true

  @spec new_page_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def new_page_modal(assigns) do
    ~H"""
    <Modal.modal id="new-booking-page-modal" show={@show} on_cancel={@on_cancel}>
      <:header>{dgettext("dashboard_booking_pages", "New booking page")}</:header>

      <.form
        :if={@show}
        for={@form}
        id="new-booking-page-form"
        phx-change="validate_new_page"
        phx-submit="create_page"
        phx-target={@target}
        class="space-y-6"
      >
        <.input
          field={used_errors(@form[:name])}
          label={dgettext("dashboard_booking_pages", "Page name")}
          maxlength={BookingPageSchema.name_max_length()}
          phx-hook="AutoFocus"
        >
          <:description>
            {dgettext(
              "dashboard_booking_pages",
              "For you only: it labels the page in your dashboard."
            )}
          </:description>
        </.input>
        <%!-- The description is the link itself, completed as the address is
        typed, so the field explains itself in one line. --%>
        <.input
          field={used_errors(@form[:slug])}
          label={dgettext("dashboard_booking_pages", "Address")}
        >
          <:description>
            <AddressPreview.address_preview
              id="new-booking-page-address-preview"
              username={@username}
              slug={@form[:slug].value}
            />
          </:description>
        </.input>
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_booking_pages",
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
            {dgettext("dashboard_booking_pages", "Cancel")}
          </.action_button>
          <.action_button type="submit">
            {dgettext("dashboard_booking_pages", "Create page")}
          </.action_button>
        </div>
      </.form>
    </Modal.modal>
    """
  end

  # LiveView marks a field the host has not touched yet as unused on every
  # change, and sends no such marks on submit, so a submit shows every error.
  defp used_errors(field),
    do: if(used_input?(field), do: field, else: %{field | errors: []})
end
