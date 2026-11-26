defmodule TymeslotWeb.E2E.ModalFocusTrapTest do
  @moduledoc """
  Keyboard containment in the dashboard's modals (`ModalFocusTrap`, in
  `assets/js/ui_interaction_hooks.js`): an open modal takes the focus, Tab
  and Shift+Tab wrap around inside it instead of walking into the page
  behind, Escape closes it, and the focus goes back to the button that
  opened it.

  A modal is shown in one of two ways, and the hook covers both: it is
  inserted while open and removed when closed (the location form), or it
  stays in the page and its overlay's inline `display` is switched (the
  time-off form). Only a browser moves focus, so this lives here.

  Where the focus is gets asserted with a `:focus` query, which `assert_has`
  retries: the modal moves the focus a frame after it paints, and hands it
  back only once the server has closed it.
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :ui

  @venue_modal "#venue-form-modal"
  @venue_name "#venue-form input[name='venue[name]']"
  @venue_save "#venue-form button[type='submit']"
  @venue_close "#venue-form-modal .modal-close"
  @add_venue "[data-testid='locations-empty'] [data-testid='add-venue']"

  @time_off_modal "#time-off-form-modal"
  @add_time_off "[data-testid='add-time-off']"

  # How many Tabs the containment check presses: well past the number of
  # controls in the location form, so a way out would be met on the way.
  @tab_presses 10

  feature "the location form keeps Tab inside it and hands the focus back on Escape",
          %{session: session} do
    {session, _user} = log_in_via_browser(session)

    session =
      session
      |> visit("/dashboard/locations")
      |> wait_for_live()
      |> click(css(@add_venue))
      |> assert_has(css(@venue_modal))
      # The form opens ready to type its name, the field it marks AutoFocus.
      |> assert_has(css("#{@venue_name}:focus"))
      # Back from the first stop, the close button, lands on the last, Save.
      |> shift_tab_to(@venue_close)
      |> shift_tab()
      |> assert_has(css("#{@venue_save}:focus"))
      # And on from the last lands on the first.
      |> send_keys([:tab])
      |> assert_has(css("#{@venue_close}:focus"))

    # However far the organiser tabs, the focus stays in the dialog.
    session =
      Enum.reduce(1..@tab_presses, session, fn _press, session ->
        session
        |> send_keys([:tab])
        |> assert_has(css("#{@venue_modal} :focus"))
      end)

    session
    |> send_keys([:escape])
    |> assert_has(css(@venue_modal, count: 0, visible: :any))
    |> assert_has(css("#{@add_venue}:focus"))
  end

  feature "the time-off form, shown and hidden in place, takes and returns the focus",
          %{session: session} do
    {session, _user} = log_in_via_browser(session)

    session
    |> visit("/dashboard/availability")
    |> wait_for_live()
    |> assert_has(css("#{@time_off_modal}[style*='display: none']", visible: :any))
    |> click(css(@add_time_off))
    |> assert_has(css("#{@time_off_modal}[style*='display: flex']"))
    |> assert_has(css("#{@time_off_modal} :focus"))
    |> send_keys([:escape])
    |> assert_has(css("#{@time_off_modal}[style*='display: none']", visible: :any))
    |> assert_has(css("#{@add_time_off}:focus"))
  end

  # Presses Shift+Tab until `selector` holds the focus, checking on the way
  # that the focus never leaves the open modal. Read at once rather than with
  # `has?/2`, which waits out Wallaby's whole timeout before saying no.
  defp shift_tab_to(session, selector, tries \\ 10) do
    focused? =
      evaluate_script(
        session,
        "return document.activeElement === document.querySelector(#{Jason.encode!(selector)})"
      )

    cond do
      focused? ->
        session

      tries == 0 ->
        flunk("Shift+Tab never reached #{selector}")

      true ->
        session
        |> shift_tab()
        |> assert_has(css("#{@venue_modal} :focus"))
        |> shift_tab_to(selector, tries - 1)
    end
  end

  # The driver treats a modifier as a toggle that outlives the call, so Shift
  # is pressed again after the Tab to let it go; otherwise the next keys
  # would be sent shifted, and the next Shift+Tab would be a plain Tab.
  defp shift_tab(session), do: send_keys(session, [:shift, :tab, :shift])
end
