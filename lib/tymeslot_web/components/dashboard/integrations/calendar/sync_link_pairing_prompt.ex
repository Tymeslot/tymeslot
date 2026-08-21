defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.SyncLinkPairingPrompt do
  @moduledoc """
  The prompt shown when the organiser has fewer than two calendars a link can
  name.

  Extracted from `SyncLinksSettingsComponent` for the same reason the matrix
  was: that module sits at the line budget the analyser enforces, and this is
  self-contained markup that answers one question.

  ## Why there are two prompts and not one

  The grid needs two *usable* calendars, and a calendar stops being usable for
  two unrelated reasons: the organiser never connected it, or it was connected
  and its authorisation lapsed. A calendar in the second state is deactivated,
  which drops it out of the source list exactly as if it had never existed.

  Counting alone cannot tell those apart, and the count was all this prompt
  used to read. An organiser whose two Google accounts had both expired was
  told to "connect a second calendar" — advice to add a third calendar to
  someone who already had two, while the link between them sat in the database
  with no row left to draw in. Naming the calendars that need reconnecting is
  what turns the message back into an instruction.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.DisplayHelpers

  @doc """
  Renders nothing when a link can already be made.

  `reconnectable` is the labels of calendars the organiser has that the grid
  cannot use until they are reconnected; it decides which of the two prompts
  applies.
  """
  attr :source_count, :integer, required: true
  attr :integrations, :list, required: true

  @spec sync_link_pairing_prompt(map()) :: Phoenix.LiveView.Rendered.t()
  def sync_link_pairing_prompt(assigns) do
    assigns = assign(assigns, :reconnectable, reconnectable(assigns.integrations))

    ~H"""
    <div :if={@source_count < 2}>
      <.info_box :if={@reconnectable != []} variant={:warning}>
        {dngettext(
          "dashboard_integrations",
          "%{names} needs reconnecting before it can mirror. Reconnect it under Calendars.",
          "%{names} need reconnecting before they can mirror. Reconnect them under Calendars.",
          length(@reconnectable),
          names: Enum.join(@reconnectable, ", ")
        )}
      </.info_box>

      <.info_box :if={@reconnectable == []} variant={:info}>
        {dgettext(
          "dashboard_integrations",
          "Connect a second calendar before setting up mirroring."
        )}
      </.info_box>
    </div>
    """
  end

  # Calendars the organiser already has, which the grid cannot use until they
  # are reconnected. Named rather than counted: "Work Google needs reconnecting"
  # is actionable where "a calendar is unavailable" is not, and the organiser is
  # usually looking at more than one.
  defp reconnectable(integrations) do
    for integration <- integrations,
        not integration.is_active,
        do: DisplayHelpers.integration_label(integration)
  end
end
