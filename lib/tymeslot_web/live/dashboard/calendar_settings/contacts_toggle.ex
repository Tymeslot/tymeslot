defmodule TymeslotWeb.Dashboard.CalendarSettings.ContactsToggle do
  @moduledoc """
  Whether a calendar connection's address books suggest contacts wherever the
  host types in whom to invite (`Tymeslot.Contacts`): the tile on its card,
  and the handler that flips it. Offered only on connections whose server
  keeps address books beside its calendars (`Contacts.supported_provider?/1`).
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Contacts
  alias Tymeslot.Integrations.Calendar
  alias TymeslotWeb.Dashboard.CalendarSettings.Helpers
  alias TymeslotWeb.Live.Shared.Flash

  attr :integration, :map, required: true
  attr :myself, :any, required: true

  @doc "The tile, or nothing for a connection that keeps no address books."
  @spec contacts_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def contacts_toggle(assigns) do
    assigns = assign(assigns, :enabled?, Map.get(assigns.integration, :use_for_contacts, false))

    ~H"""
    <.tooltip
      :let={tip}
      :if={Contacts.supported_provider?(Map.get(@integration, :provider))}
      id={"calendar-#{@integration.id}-contacts-tip"}
      text={
        dgettext(
          "dashboard_calendar_settings",
          "Suggest contacts from this account's address books when you invite people"
        )
      }
    >
      <button
        type="button"
        phx-click="toggle_use_for_contacts"
        phx-value-id={@integration.id}
        phx-target={@myself}
        class={Helpers.tile_class(:neutral)}
        aria-pressed={to_string(@enabled?)}
        aria-describedby={tip}
        data-testid="use-for-contacts-toggle"
      >
        <.icon
          name={if @enabled?, do: "hero-check-circle", else: "hero-user-circle"}
          class="w-4 h-4"
        /><span>{dgettext("dashboard_calendar_settings", "Contact suggestions")}</span>
      </button>
    </.tooltip>
    """
  end

  @doc """
  Flips the setting on the connection `id` of the host's, among the ones
  the page shows. Returns `{:ok, updated}` once it is stored, after saying
  so; anything else has already been told to the host, or was a stale id.
  """
  @spec toggle(pos_integer(), [map()], String.t()) :: {:ok, map()} | :unchanged
  def toggle(user_id, integrations, id) do
    with {int_id, ""} <- Integer.parse(to_string(id)),
         %{} = integration <- Enum.find(integrations, &(&1.id == int_id)),
         {:ok, updated} <-
           Calendar.set_use_for_contacts(user_id, int_id, not integration.use_for_contacts) do
      Flash.info(message(updated.use_for_contacts))
      {:ok, updated}
    else
      {:error, {:rate_limited, message}} ->
        Flash.error(message)
        :unchanged

      _not_changed ->
        :unchanged
    end
  end

  defp message(true),
    do:
      dgettext(
        "dashboard_calendar_settings",
        "Contacts from this account are now suggested when you invite people."
      )

  defp message(false),
    do:
      dgettext(
        "dashboard_calendar_settings",
        "Contacts from this account are no longer suggested."
      )
end
