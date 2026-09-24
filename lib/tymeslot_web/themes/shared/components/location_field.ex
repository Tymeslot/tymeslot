defmodule TymeslotWeb.Themes.Shared.Components.LocationField do
  @moduledoc """
  Shared "where shall we meet?" picker for scheduling themes.

  Renders the meeting type's locations as a horizontal row of toggles, each
  with its kind's icon, and beneath it the chosen option's detail (its
  address, say). Only the chosen option's detail is shown: a row of toggles
  has no room for an address on every one. Two follow-up questions appear
  under the row when the chosen location asks them: which video provider,
  as a second row of toggles, when a video location offers several; and a
  number input when a phone location asks the booker for theirs.

  The location row itself is left out when there is only one location, as
  happens for a single video location offering several providers: the
  provider row is then the whole question.

  All state lives in the parent LiveView (`location_options`,
  `selected_location_id`, `video_choices`, `selected_video_id`,
  `location_phone`, `location_error`); this component is purely
  presentational and forwards its events to the booking-step component via
  `phx-target`, which relays them to the LiveView.

  The markup is theme-agnostic and ships no styling of its own. Each theme
  styles the `location-*` classes in its own `booking-form.css`, scoped to
  `html.<theme>-theme`, exactly as it does for `guest-*`.

  Each toggle wraps a visually hidden native radio rather than being a
  button, because this is a single choice from a short list and the browser
  already gives that arrow-key navigation and a group role for free. They
  sit outside the booking `<form>` and post nothing: the choice is pushed as
  an event and read from socket state.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingTypes.LocationOption
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Helpers.LocationIcons

  attr :location_options, :list, required: true
  attr :selected_location_id, :string, default: nil
  attr :video_choices, :list, default: [], doc: "the chosen option's providers, when a video call"
  attr :selected_video_id, :integer, default: nil
  attr :location_phone, :string, default: ""
  attr :location_error, :string, default: nil
  attr :phone_required, :boolean, default: false
  attr :target, :any, required: true

  @spec location_field(map()) :: Phoenix.LiveView.Rendered.t()
  def location_field(assigns) do
    assigns =
      assign(
        assigns,
        :detail,
        assigns.location_options
        |> Enum.find(&(&1.id == assigns.selected_location_id))
        |> detail_line()
      )

    ~H"""
    <div class="location-field" data-testid="location-field">
      <fieldset :if={length(@location_options) > 1} class="location-group">
        <legend class="location-field__label">
          {dgettext("booking", "Where shall we meet?")}
        </legend>

        <div class="location-options">
          <label
            :for={option <- @location_options}
            class={[
              "location-option",
              option.id == @selected_location_id && "location-option--selected"
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
            <CoreComponents.icon name={LocationIcons.icon(option.kind)} class="location-option__icon" />
            <span class="location-option__title">{option.label}</span>
          </label>
        </div>
      </fieldset>

      <fieldset
        :if={length(@video_choices) > 1}
        class="location-group location-group--video"
        data-testid="video-provider-field"
      >
        <legend class="location-field__label">
          {dgettext("booking", "Which video service?")}
        </legend>

        <div class="location-options">
          <label
            :for={choice <- @video_choices}
            class={[
              "location-option",
              choice.id == @selected_video_id && "location-option--selected"
            ]}
            data-testid="video-provider-option"
            data-video-integration-id={choice.id}
          >
            <input
              type="radio"
              name="location_video_provider"
              class="location-option__radio"
              value={choice.id}
              checked={choice.id == @selected_video_id}
              phx-click="select_video_provider"
              phx-value-id={choice.id}
              phx-target={@target}
            />
            <CoreComponents.icon name={LocationIcons.icon("video")} class="location-option__icon" />
            <span class="location-option__title">{choice.name}</span>
          </label>
        </div>
      </fieldset>

      <p :if={@detail} class="location-field__detail" data-testid="location-detail">
        {@detail}
      </p>

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
    </div>
    """
  end

  # The line under the toggles for the chosen option: what the booker needs
  # to know about it. A video option deliberately shows nothing, because its
  # join link does not exist until the booking is made.
  defp detail_line(%LocationOption{kind: "video"}), do: nil

  defp detail_line(%LocationOption{kind: "phone", collect_from_guest: true}),
    do: dgettext("booking", "We'll call you")

  defp detail_line(%LocationOption{details: details})
       when is_binary(details) and details != "",
       do: details

  defp detail_line(_option_or_nil), do: nil
end
