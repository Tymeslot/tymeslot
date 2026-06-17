defmodule TymeslotWeb.Themes.Shared.Components.GuestField do
  @moduledoc """
  Shared "add guests" token field for scheduling themes.

  Renders a collapsible chip/token input the invitee uses to add guest email
  addresses to their booking. All state lives in the parent LiveView
  (`guest_emails`, `guest_input`, `guest_error`, `guests_open`); this component
  is purely presentational and forwards its events to the booking-step
  component via `phx-target`, which relays them to the LiveView.

  The markup is theme-agnostic and ships no styling of its own — each theme
  styles the `guest-*` classes in its own `booking-form.css`, scoped to
  `html.<theme>-theme`, so the field reads as native to that theme.

  The add input lives in its own `<form>` (a sibling of the main booking form,
  never nested) so pressing Enter adds a guest instead of submitting the
  booking.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  attr :guest_emails, :list, required: true
  attr :guest_input, :string, default: ""
  attr :guest_error, :string, default: nil
  attr :guests_open, :boolean, default: false
  attr :max_guests, :integer, required: true
  attr :target, :any, required: true

  @spec guest_field(map()) :: Phoenix.LiveView.Rendered.t()
  def guest_field(assigns) do
    ~H"""
    <div class="guest-field" data-testid="guest-field">
      <%= if @guests_open or @guest_emails != [] do %>
        <div class="guest-field__header">
          <span class="guest-field__label">{gettext("Guests")}</span>
          <span class="guest-field__count">{length(@guest_emails)}/{@max_guests}</span>
        </div>

        <ul :if={@guest_emails != []} class="guest-chips">
          <li :for={email <- @guest_emails} class="guest-chip" data-testid="guest-chip">
            <span class="guest-chip__avatar" aria-hidden="true">{guest_initial(email)}</span>
            <span class="guest-chip__email">{email}</span>
            <button
              type="button"
              class="guest-chip__remove"
              phx-click="remove_guest"
              phx-value-email={email}
              phx-target={@target}
              aria-label={gettext("Remove guest %{email}", email: email)}
            >
              ×
            </button>
          </li>
        </ul>

        <form
          :if={length(@guest_emails) < @max_guests}
          class="guest-add"
          phx-submit="add_guest"
          phx-change="guest_input_change"
          phx-target={@target}
        >
          <input
            type="email"
            name="guest_email"
            class="guest-add__input"
            value={@guest_input}
            placeholder={gettext("guest@example.com")}
            autocomplete="off"
            phx-debounce="blur"
            aria-label={gettext("Guest email address")}
            data-testid="guest-input"
          />
          <button type="submit" class="guest-add__button" data-testid="guest-add">
            {gettext("Add")}
          </button>
        </form>

        <p :if={@guest_error} class="guest-field__error" role="alert">{@guest_error}</p>
      <% else %>
        <button
          type="button"
          class="guest-field__toggle"
          phx-click="toggle_guests"
          phx-target={@target}
          data-testid="guest-toggle"
        >
          {gettext("+ Add guests")}
        </button>
      <% end %>
    </div>
    """
  end

  defp guest_initial(email) do
    case email |> to_string() |> String.trim() |> String.first() do
      nil -> "?"
      letter -> String.upcase(letter)
    end
  end
end
