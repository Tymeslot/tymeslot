defmodule TymeslotWeb.Themes.Shared.Components.LocationField do
  @moduledoc """
  Shared "where shall we meet?" picker for scheduling themes.

  Renders the meeting type's locations as a radio group the booker picks
  from, plus a number input when the chosen location asks them for their
  own phone number. All state lives in the parent LiveView
  (`location_options`, `selected_location_id`, `location_phone`,
  `location_error`); this component is purely presentational and forwards
  its events to the booking-step component via `phx-target`, which relays
  them to the LiveView.

  The markup is theme-agnostic and ships no styling of its own. Each theme
  styles the `location-*` classes in its own `booking-form.css`, scoped to
  `html.<theme>-theme`, exactly as it does for `guest-*`.

  Native radio inputs rather than buttons, because this is a single choice
  from a short list and the browser already gives that arrow-key navigation
  and a group role for free. They sit outside the booking `<form>` and post
  nothing: the choice is pushed as an event and read from socket state.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.LocationOption

  attr :location_options, :list, required: true
  attr :selected_location_id, :string, default: nil
  attr :location_phone, :string, default: ""
  attr :location_error, :string, default: nil
  attr :phone_required, :boolean, default: false
  attr :target, :any, required: true

  @spec location_field(map()) :: Phoenix.LiveView.Rendered.t()
  def location_field(assigns) do
    ~H"""
    <fieldset class="location-field" data-testid="location-field">
      <legend class="location-field__label">
        {dgettext("booking", "Where shall we meet?")}
      </legend>

      <ul class="location-options">
        <li :for={option <- @location_options} class="location-option">
          <label
            class={[
              "location-option__label",
              option.id == @selected_location_id && "location-option__label--selected"
            ]}
            data-testid="location-option"
            data-location-id={option.id}
          >
            <input
              type="radio"
              name="location_option"
              class="location-option__radio"
              value={option.id}
              checked={option.id == @selected_location_id}
              phx-click="select_location"
              phx-value-id={option.id}
              phx-target={@target}
            />
            <span class="location-option__text">
              <span class="location-option__title">{option.label}</span>
              <span :if={detail_line(option)} class="location-option__detail">
                {detail_line(option)}
              </span>
            </span>
          </label>
        </li>
      </ul>

      <%!-- The number lives in its own <form> (a sibling of the booking
           form, never nested), so `phx-change` carries it on every input
           event. A bare `phx-keyup` would miss a value that arrives without
           keystrokes, which is exactly how a pasted or autofilled number
           arrives, and the booking would then be refused for a number the
           booker can see in the field. --%>
      <form
        :if={@phone_required}
        id="location-phone-form"
        class="location-phone"
        phx-change="location_phone_change"
        phx-submit="location_phone_change"
        phx-target={@target}
        novalidate
      >
        <label class="location-phone__label" for="location-phone-input">
          {dgettext("booking", "Your phone number")}
        </label>
        <input
          type="tel"
          id="location-phone-input"
          name="location_phone"
          class="location-phone__input"
          value={@location_phone}
          placeholder="+44 7700 900123"
          autocomplete="tel"
          phx-debounce="300"
          data-testid="location-phone"
        />
      </form>

      <p :if={@location_error} class="location-field__error" data-testid="location-error">
        {@location_error}
      </p>
    </fieldset>
    """
  end

  # The second line under an option's name: what actually distinguishes it
  # from its neighbours. A video option deliberately shows nothing, because
  # its join link does not exist until the booking is made.
  defp detail_line(%LocationOption{kind: "video"}), do: nil

  defp detail_line(%LocationOption{kind: "phone", collect_from_guest: true}),
    do: dgettext("booking", "We'll call you")

  defp detail_line(%LocationOption{details: details})
       when is_binary(details) and details != "",
       do: details

  defp detail_line(_option), do: nil
end
